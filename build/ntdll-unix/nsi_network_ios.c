/*
 * nsiproxy.sys
 *
 * Copyright 2021 Huw Davies
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */
/* iOS uses Wine's BSD interface/address providers without the driver service.
 * Keep the dispatcher ABI and size validation shared across native and WoW callers.
 * MADEIRA_NSI_NETWORK_TABLES=0 restores the original unsupported-table behavior. */
#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "ifdef.h"
#define __WINE_INIT_NPI_MODULEID
#define USE_WS_PREFIX
#include "netiodef.h"
#include "wine/nsi.h"
#include "wine/debug.h"
#include "../../wine/dlls/nsiproxy.sys/unix_private.h"
WINE_DEFAULT_DEBUG_CHANNEL(nsi);

static const struct module *modules[] =
{
    &ndis_module,
    &ipv4_module,
    &ipv6_module,
};

static const struct module_table *get_module_table( const NPI_MODULEID *id, UINT table )
{
    const char *enabled = getenv( "MADEIRA_NSI_NETWORK_TABLES" );
    const struct module_table *entry;
    int i;

    if (enabled && !strcmp( enabled, "0" )) return NULL;
    if (!id) return NULL;
    for (i = 0; i < ARRAY_SIZE(modules); i++)
        if (NmrIsEqualNpiModuleId( modules[i]->module, id ))
            for (entry = modules[i]->tables; entry->table != ~0u; entry++)
                if (entry->table == table) return entry;

    return NULL;
}

NTSTATUS nsi_enumerate_all_ex( struct nsi_enumerate_all_ex *params )
{
    const struct module_table *entry = get_module_table( params->module, params->table );
    UINT sizes[4] = { params->key_size, params->rw_size, params->dynamic_size, params->static_size };
    void *data[4] = { params->key_data, params->rw_data, params->dynamic_data, params->static_data };
    int i;

    if (!entry || !entry->enumerate_all)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    for (i = 0; i < ARRAY_SIZE(sizes); i++)
    {
        if (!sizes[i]) data[i] = NULL;
        else if (!data[i] || sizes[i] != entry->sizes[i]) return STATUS_INVALID_PARAMETER;
    }

    NTSTATUS status = entry->enumerate_all( data[0], sizes[0], data[1], sizes[1], data[2], sizes[2], data[3], sizes[3], &params->count );
    static unsigned int reports;
    if (__atomic_fetch_add( &reports, 1, __ATOMIC_RELAXED ) < 16)
        dprintf( 2, "[nsi-network] ml1290 module=%08x table=%u status=%08x count=%u\n",
                 params->module->Guid.Data1, (UINT)params->table, (UINT)status, (UINT)params->count );
    return status;
}

NTSTATUS nsi_get_all_parameters_ex( struct nsi_get_all_parameters_ex *params )
{
    const struct module_table *entry = get_module_table( params->module, params->table );
    void *rw = params->rw_data;
    void *dyn = params->dynamic_data;
    void *stat = params->static_data;

    if (!entry || !entry->get_all_parameters)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    if ((params->key_size && !params->key) || params->key_size != entry->sizes[0]) return STATUS_INVALID_PARAMETER;
    if (!params->rw_size) rw = NULL;
    else if (!rw || params->rw_size != entry->sizes[1]) return STATUS_INVALID_PARAMETER;
    if (!params->dynamic_size) dyn = NULL;
    else if (!dyn || params->dynamic_size != entry->sizes[2]) return STATUS_INVALID_PARAMETER;
    if (!params->static_size) stat = NULL;
    else if (!stat || params->static_size != entry->sizes[3]) return STATUS_INVALID_PARAMETER;

    return entry->get_all_parameters( params->key, params->key_size, rw, params->rw_size,
                                      dyn, params->dynamic_size, stat, params->static_size );
}

NTSTATUS nsi_get_parameter_ex( struct nsi_get_parameter_ex *params )
{
    const struct module_table *entry = get_module_table( params->module, params->table );

    if (!entry || !entry->get_parameter)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    if (params->param_type > 2) return STATUS_INVALID_PARAMETER;
    if ((params->key_size && !params->key) || params->key_size != entry->sizes[0]) return STATUS_INVALID_PARAMETER;
    if ((params->data_size && !params->data) ||
        params->data_offset > entry->sizes[params->param_type + 1] ||
        params->data_size > entry->sizes[params->param_type + 1] - params->data_offset)
        return STATUS_INVALID_PARAMETER;
    return entry->get_parameter( params->key, params->key_size, params->param_type,
                                 params->data, params->data_size, params->data_offset );
}

