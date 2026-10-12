/* Win64 fixture for the guarded RunState write sites; no supplied binary.
 * Link at 0x1740e0. The labels must coincide with the production hook sites. */
.intel_syntax noprefix
.section .fixture,"ax"
.global fixture_run, fixture_install, fixture_restore
fixture_run:
    mov qword ptr [rsp+8], rbx
    push rdi
    sub rsp, 0x40
    mov rdi, qword ptr [rcx+0x40]
    mov rbx, rcx
    mov qword ptr [rsp+0x20], rdx
    mov qword ptr [rsp+0x28], 0
    mov byte ptr [rsp+0x30], 0
    test rdi, rdi
    jz initial
    mov eax, dword ptr [rdi+0x14]
    inc eax
    mov dword ptr [rsp+0x34], eax
    jmp ready
initial:
    mov dword ptr [rsp+0x34], 1
ready:
    lea rax, [rsp+0x20]
fixture_install:
    mov qword ptr [rcx+0x40], rax
    mov rax, qword ptr [rcx]
    call qword ptr [rax+0x28]
fixture_restore:
    mov qword ptr [rbx+0x40], rdi
    mov rbx, qword ptr [rsp+0x50]
    add rsp, 0x40
    pop rdi
    ret
