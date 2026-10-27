#!/usr/bin/env python3
"""Check the production PE layout fingerprint with real Wine PE headers."""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
s = (root/'build/ntdll-unix/virtual_ios.c').read_text()
a = s.index('static uint64_t ios_pool_image_tag(')
fn = s[a:s.index('\n}', a)+2]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "windef.h"
#include "winnt.h"
FUNCTION
int main(void) {
    unsigned char image[0x2000] = {0};
    IMAGE_DOS_HEADER *dos=(void *)image;
    IMAGE_NT_HEADERS *nt=(void *)(image+0x80);
    dos->e_magic=IMAGE_DOS_SIGNATURE; dos->e_lfanew=0x80;
    nt->Signature=IMAGE_NT_SIGNATURE;
    nt->FileHeader.SizeOfOptionalHeader=sizeof(nt->OptionalHeader);
    nt->FileHeader.NumberOfSections=1;
    nt->OptionalHeader.SizeOfImage=sizeof(image);
    IMAGE_SECTION_HEADER *sec=IMAGE_FIRST_SECTION(nt);
    sec->VirtualAddress=0x1000; sec->Misc.VirtualSize=0x1000;
    uint64_t tag=ios_pool_image_tag(image,sizeof(image),0x4000);
    assert(tag && tag==ios_pool_image_tag(image,sizeof(image),0x4000));
    sec->Characteristics=IMAGE_SCN_MEM_WRITE;
    assert(tag!=ios_pool_image_tag(image,sizeof(image),0x4000));
    sec->Characteristics=0;
    assert(tag!=ios_pool_image_tag(image,sizeof(image),0x8000));
    dos->e_lfanew=-1; assert(!ios_pool_image_tag(image,sizeof(image),0x4000));
    dos->e_lfanew=sizeof(image)-1; assert(!ios_pool_image_tag(image,sizeof(image),0x4000));
    dos->e_lfanew=0x80;
    nt->FileHeader.NumberOfSections=0xffff; assert(!ios_pool_image_tag(image,sizeof(image),0x4000));
    nt->FileHeader.NumberOfSections=1;
    nt->FileHeader.SizeOfOptionalHeader=0xffff; assert(!ios_pool_image_tag(image,sizeof(image),0x4000));
    nt->FileHeader.SizeOfOptionalHeader=0; assert(!ios_pool_image_tag(image,sizeof(image),0x4000));
    puts("PASS: layout tags differ for writable pages and allocation size; malformed headers are rejected");
}
'''.replace('FUNCTION',fn)
headers = Path(os.environ.get('WINE_SOURCE',root/'wine'))/'include'
with tempfile.TemporaryDirectory() as d:
    c,exe=Path(d)/'tag.c',Path(d)/'tag'
    c.write_text(code)
    subprocess.run(['cc','-std=c11','-D__WINESRC__','-fsanitize=address,undefined','-I',str(headers),str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
