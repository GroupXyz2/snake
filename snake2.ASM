; ============================================================
;  SNAKE 2  -  FASM, 64-bit Windows, fully custom window
;
;  Same game as snake.asm, but now the WINDOW is part of it:
;
;   * Cut-corner window shape (SetWindowRgn) with accent outline
;     lines that we draw ourselves along the diagonal edges.
;     The cut corners are truly gone: clicks pass through them.
;   * Fade in at launch, fade out on quit (window opacity).
;   * Ghost mode: the window turns see-through when unfocused.
;   * Eat kick: the whole window lurches in the snake's direction
;     every time you eat, then settles back.
;   * Crash shake: on game over the window rattles on the desktop.
;   * T toggles "always on top" (a green TOP tag shows when on).
;
;  Controls: arrows / WASD, SPACE = start/restart, T = on top,
;            ESC = quit. Drag the title bar, red square closes.
;
;  Two timers: id 1 = game step (TICK ms), id 2 = window
;  animation (16 ms) that drives fade, kick and shake.
; ============================================================
format PE64 GUI 5.0
entry start
include 'win64a.inc'                 ; only used for the import table macros

W     = 400                          ; window size in pixels
H     = 330
GW    = 20                           ; board size in cells
GH    = 15
CELL  = 20                           ; cell size in pixels
TOP   = 30                           ; height of the title bar
TICK  = 120                          ; milliseconds per game step
CUT   = 16                           ; size of the cut corners (top-left, bottom-right)

COL_BORDER = 0x00384058
COL_TITLE  = 0x00181C28
COL_A      = 0x00161B28              ; checkerboard colors
COL_B      = 0x00121722
COL_TEXT   = 0x00E6EBF5
COL_DIM    = 0x008A93A8
COL_PANEL  = 0x000E111A
COL_FOOD   = 0x00F0506A
COL_FOODHI = 0x00FF9AAA
COL_EYE    = 0x00101820
COL_CLOSE  = 0x00C03030
COL_WHITE  = 0x00FFFFFF
COL_GREEN  = 0x0070E8A0

section '.text' code readable executable

; ---------------------------------------------------------
start:
    sub  rsp, 232                    ; wc = rsp+96 (80 bytes), msg = rsp+176 (48 bytes)

    rdtsc                            ; CPU cycle counter = our random seed
    or   eax, 1
    mov  [seed], eax
    call newgame
    call render                      ; first frame is drawn before the window exists

    xor  ecx, ecx
    call [GetModuleHandleA]
    mov  rbx, rax                    ; RBX = our HINSTANCE

    mov  dword [rsp+96],  80         ; WNDCLASSEXA.cbSize
    mov  dword [rsp+100], 0          ; style
    lea  rax, [WndProc]
    mov  [rsp+104], rax              ; lpfnWndProc
    mov  dword [rsp+112], 0
    mov  dword [rsp+116], 0
    mov  [rsp+120], rbx              ; hInstance
    mov  qword [rsp+128], 0          ; hIcon
    xor  ecx, ecx
    mov  edx, 32512                  ; IDC_ARROW
    call [LoadCursorA]
    mov  [rsp+136], rax              ; hCursor
    mov  qword [rsp+144], 0          ; no background brush: we paint every pixel
    mov  qword [rsp+152], 0
    lea  rax, [classname]
    mov  [rsp+160], rax
    mov  qword [rsp+168], 0
    lea  rcx, [rsp+96]
    call [RegisterClassExA]

    mov  ecx, 0xC0000                ; WS_EX_LAYERED (opacity) | WS_EX_APPWINDOW (taskbar button)
    lea  rdx, [classname]
    lea  r8,  [title]
    mov  r9d, 0x90000000             ; WS_POPUP | WS_VISIBLE  (no frame at all)
    mov  dword [rsp+32], 300         ; x
    mov  dword [rsp+40], 200         ; y
    mov  dword [rsp+48], W
    mov  dword [rsp+56], H
    mov  qword [rsp+64], 0
    mov  qword [rsp+72], 0
    mov  [rsp+80], rbx
    mov  qword [rsp+88], 0
    call [CreateWindowExA]
    mov  rsi, rax                    ; RSI = hwnd

    mov  rcx, rsi                    ; start fully transparent, the animation fades us in
    xor  edx, edx
    xor  r8d, r8d                    ; alpha = 0
    mov  r9d, 2                      ; LWA_ALPHA
    call [SetLayeredWindowAttributes]

    lea  rcx, [poly]                 ; cut-corner outline: clip the window to a polygon
    mov  edx, 6
    mov  r8d, 1                      ; ALTERNATE fill mode
    call [CreatePolygonRgn]
    mov  rcx, rsi
    mov  rdx, rax                    ; the region now belongs to Windows
    mov  r8d, 1                      ; redraw
    call [SetWindowRgn]

    mov  rcx, rsi                    ; timer 1: game clock
    mov  edx, 1
    mov  r8d, TICK
    xor  r9d, r9d
    call [SetTimer]
    mov  rcx, rsi                    ; timer 2: window animation, ~60 fps
    mov  edx, 2
    mov  r8d, 16
    xor  r9d, r9d
    call [SetTimer]
    mov  rcx, rsi
    call [SetForegroundWindow]

msgloop:
    lea  rcx, [rsp+176]
    xor  edx, edx
    xor  r8d, r8d
    xor  r9d, r9d
    call [GetMessageA]
    test eax, eax
    jle  done
    lea  rcx, [rsp+176]
    call [DispatchMessageA]          ; Windows calls WndProc from here
    jmp  msgloop
done:
    xor  ecx, ecx
    call [ExitProcess]

; ---------------------------------------------------------
; Window procedure. Windows requires us to preserve
; rbx, rsi, rdi, r12-r15, so we push them and use them freely.
; ---------------------------------------------------------
WndProc:                             ; rcx=hwnd, edx=msg, r8=wparam, r9=lparam
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub  rsp, 176                    ; 96 outgoing args + 72 PAINTSTRUCT/RECT (rsp+96) + hwnd (rsp+168)
    mov  [rsp+168], rcx
    cmp  edx, 0x000F                 ; WM_PAINT
    je   .paint
    cmp  edx, 0x0113                 ; WM_TIMER
    je   .timer
    cmp  edx, 0x0100                 ; WM_KEYDOWN
    je   .key
    cmp  edx, 0x0201                 ; WM_LBUTTONDOWN
    je   .click
    cmp  edx, 0x0006                 ; WM_ACTIVATE
    je   .activate
    cmp  edx, 0x0002                 ; WM_DESTROY
    je   .quit
.def:
    call [DefWindowProcA]            ; everything else: default handling
.out:
    add  rsp, 176
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    ret

.zero:
    xor  eax, eax
    jmp  .out

.quit:                               ; really leave the message loop
    xor  ecx, ecx
    call [PostQuitMessage]
    jmp  .zero

.fadeout:                            ; polite quit: fade to 0, the animation then quits
    mov  dword [target], 0
    mov  dword [quitting], 1
    jmp  .zero

.activate:                           ; wParam low word 0 = we lost focus
    cmp  dword [quitting], 0
    jne  .def
    mov  dword [target], 255
    test r8w, r8w
    jnz  .def
    mov  dword [target], 170         ; ghost mode while unfocused
    jmp  .def                        ; DefWindowProc must still run (it sets keyboard focus)

; ---- timers --------------------------------------------------
.timer:
    cmp  r8d, 2                      ; wParam = timer id
    je   .anim
    call step                        ; timer 1: one game step
    call render
    mov  rcx, [rsp+168]
    xor  edx, edx                    ; whole window
    xor  r8d, r8d                    ; don't erase background
    call [InvalidateRect]            ; -> WM_PAINT
    jmp  .zero

.anim:                               ; timer 2: window animation
    mov  eax, [alpha]                ; ---- fade: move alpha toward target
    mov  ecx, [target]
    cmp  eax, ecx
    je   .nofade
    jl   .fup
    sub  eax, 14
    cmp  eax, ecx
    jge  .fset
    mov  eax, ecx
    jmp  .fset
.fup:
    add  eax, 14
    cmp  eax, ecx
    jle  .fset
    mov  eax, ecx
.fset:
    mov  [alpha], eax
    mov  rcx, [rsp+168]
    xor  edx, edx
    mov  r8d, eax
    mov  r9d, 2                      ; LWA_ALPHA
    call [SetLayeredWindowAttributes]
.nofade:
    cmp  dword [quitting], 0         ; ---- faded out completely? then quit
    je   .noq
    cmp  dword [alpha], 0
    jne  .noq
    xor  ecx, ecx
    call [PostQuitMessage]
.noq:
    mov  eax, [kx]                   ; ---- eat kick decays (x3/4 each frame)
    call decay
    mov  [kx], eax
    mov  eax, [ky]
    call decay
    mov  [ky], eax
    xor  r10d, r10d                  ; ---- crash shake: random jitter of +-amp
    xor  r11d, r11d
    mov  ecx, [amp]
    test ecx, ecx
    jz   .shdone
    lea  r8d, [rcx+rcx+1]            ; range = 2*amp+1
    call rnd
    xor  edx, edx
    div  r8d
    sub  edx, ecx                    ; random -amp..+amp
    mov  r10d, edx
    call rnd
    xor  edx, edx
    div  r8d
    sub  edx, ecx
    mov  r11d, edx
    dec  dword [amp]                 ; the shake fades out
.shdone:
    mov  eax, [kx]                   ; ---- total offset = kick + shake
    add  eax, r10d
    mov  ecx, [ky]
    add  ecx, r11d
    mov  r12d, eax
    sub  r12d, [ox]                  ; how far to move the window this frame
    mov  r13d, ecx
    sub  r13d, [oy]
    mov  [ox], eax
    mov  [oy], ecx
    mov  eax, r12d
    or   eax, r13d
    jz   .nomove
    mov  rcx, [rsp+168]
    lea  rdx, [rsp+96]
    call [GetWindowRect]             ; RECT at rsp+96: left, top, right, bottom
    mov  rcx, [rsp+168]
    xor  edx, edx
    mov  r8d, [rsp+96]
    add  r8d, r12d                   ; new x (relative move, so dragging still works)
    mov  r9d, [rsp+100]
    add  r9d, r13d                   ; new y
    mov  dword [rsp+32], 0
    mov  dword [rsp+40], 0
    mov  dword [rsp+48], 0x15        ; SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
    call [SetWindowPos]
.nomove:
    jmp  .zero

; ---- keyboard --------------------------------------------------
.key:
    mov  eax, r8d                    ; virtual key code
    cmp  eax, 0x1B                   ; ESC
    je   .fadeout
    cmp  eax, 0x20                   ; SPACE
    je   .space
    cmp  eax, 0x54                   ; T
    je   .pin
    lea  rdx, [keytab]
    xor  ecx, ecx
.k: cmp  al, [rdx+rcx]
    je   .found
    inc  ecx
    cmp  ecx, 8
    jb   .k
    jmp  .zero
.found:
    shr  ecx, 1                      ; 0=up 1=right 2=down 3=left
    mov  eax, [dir]
    xor  eax, 2                      ; opposite of the current direction
    cmp  eax, ecx
    je   .zero                       ; can't reverse into yourself
    mov  [nextdir], ecx
    cmp  dword [state], 2
    jne  .zero
    mov  dword [state], 0            ; first key starts the game
    jmp  .zero
.space:
    cmp  dword [state], 0
    je   .zero
    call newgame
    mov  dword [state], 0
    call render
    mov  rcx, [rsp+168]
    xor  edx, edx
    xor  r8d, r8d
    call [InvalidateRect]
    jmp  .zero
.pin:                                ; toggle always-on-top
    xor  dword [topmost], 1
    mov  rdx, -2                     ; HWND_NOTOPMOST
    cmp  dword [topmost], 0
    je   .pinset
    mov  rdx, -1                     ; HWND_TOPMOST
.pinset:
    mov  rcx, [rsp+168]
    xor  r8d, r8d
    xor  r9d, r9d
    mov  dword [rsp+32], 0
    mov  dword [rsp+40], 0
    mov  dword [rsp+48], 0x13        ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    call [SetWindowPos]
    mov  rcx, [rsp+168]              ; redraw so the TOP tag appears right away
    call render
    mov  rcx, [rsp+168]
    xor  edx, edx
    xor  r8d, r8d
    call [InvalidateRect]
    jmp  .zero

; ---- mouse -----------------------------------------------------
.click:                              ; lParam: low word = x, high word = y
    movzx eax, r9w
    mov  r10d, r9d
    shr  r10d, 16
    cmp  r10d, TOP-1
    jae  .zero                       ; below the title bar
    cmp  eax, 360
    jae  .fadeout                    ; on the red button
    call [ReleaseCapture]            ; title bar: start dragging the window
    mov  rcx, [rsp+168]
    mov  edx, 0xA1                   ; WM_NCLBUTTONDOWN
    mov  r8d, 2                      ; HTCAPTION: "the mouse went down on a title bar"
    xor  r9d, r9d
    call [SendMessageA]
    jmp  .zero

.paint:
    mov  rcx, [rsp+168]
    lea  rdx, [rsp+96]
    call [BeginPaint]                ; RAX = hdc
    mov  rcx, rax
    xor  edx, edx                    ; xDest
    xor  r8d, r8d                    ; yDest
    mov  r9d, W
    mov  dword [rsp+32], H
    mov  dword [rsp+40], 0
    mov  dword [rsp+48], 0
    mov  dword [rsp+56], 0
    mov  dword [rsp+64], H
    lea  rax, [buffer]
    mov  [rsp+72], rax               ; our pixels
    lea  rax, [bmi]
    mov  [rsp+80], rax               ; pixel format description
    mov  dword [rsp+88], 0           ; DIB_RGB_COLORS
    call [SetDIBitsToDevice]         ; copy RAM -> window
    mov  rcx, [rsp+168]
    lea  rdx, [rsp+96]
    call [EndPaint]
    jmp  .zero

; =========================================================
;  SMALL HELPERS
; =========================================================
rnd:                                 ; xorshift32: eax = next random number (clobbers edx)
    mov  eax, [seed]
    mov  edx, eax
    shl  edx, 13
    xor  eax, edx
    mov  edx, eax
    shr  edx, 17
    xor  eax, edx
    mov  edx, eax
    shl  edx, 5
    xor  eax, edx
    mov  [seed], eax
    ret

decay:                               ; eax = eax * 3 / 4, rounded toward zero
    imul eax, eax, 3
    cdq
    and  edx, 3
    add  eax, edx
    sar  eax, 2
    ret

; =========================================================
;  GAME LOGIC (pure CPU)
;  grid[cell]  : 1 where the snake is      (cell = y*GW + x)
;  queue[]     : ring buffer of the snake's cells, tail..head-1
; =========================================================
newgame:
    lea  rdi, [grid]
    xor  eax, eax
    mov  ecx, GW*GH/4
    rep  stosd                       ; clear the board
    lea  rdi, [grid]
    lea  rsi, [queue]
    mov  dword [rsi],   7*GW+8       ; snake of length 3, heading right
    mov  dword [rsi+4], 7*GW+9
    mov  dword [rsi+8], 7*GW+10
    mov  byte [rdi+7*GW+8],  1
    mov  byte [rdi+7*GW+9],  1
    mov  byte [rdi+7*GW+10], 1
    mov  dword [tail], 0
    mov  dword [head], 3
    mov  dword [hx], 10
    mov  dword [hy], 7
    mov  dword [dir], 1
    mov  dword [nextdir], 1
    mov  dword [score], 0
    mov  dword [state], 2            ; 2 = ready, 0 = playing, 1 = game over
    jmp  placefood

placefood:                           ; pick a random free cell
    mov  eax, [head]
    sub  eax, [tail]
    cmp  eax, GW*GH
    jb   .try
    mov  dword [state], 1            ; board full: you win (shown as game over)
    ret
.try:
    call rnd
    xor  edx, edx
    mov  ecx, GW*GH
    div  ecx                         ; EDX = random cell 0..299
    lea  rax, [grid]
    cmp  byte [rax+rdx], 0
    jne  .try
    mov  [food], edx
    ret

step:                                ; advance the snake one cell
    cmp  dword [state], 0
    jne  .ret
    mov  eax, [nextdir]
    mov  [dir], eax
    lea  rsi, [dxt]
    mov  edx, [hx]
    add  edx, [rsi+rax*4]            ; new x
    lea  rsi, [dyt]
    mov  r8d, [hy]
    add  r8d, [rsi+rax*4]            ; new y
    cmp  edx, GW
    jae  .dead                       ; hit a wall (negative numbers are huge unsigned)
    cmp  r8d, GH
    jae  .dead
    imul r9d, r8d, GW
    add  r9d, edx                    ; R9 = new head cell
    lea  rsi, [grid]
    lea  rdi, [queue]
    mov  eax, [tail]
    and  eax, 511
    mov  r10d, [rdi+rax*4]           ; R10 = cell of the tail
    cmp  byte [rsi+r9], 0
    je   .free
    cmp  r9d, r10d
    jne  .dead                       ; hit the body (the tail cell is fine: it moves away)
.free:
    cmp  r9d, [food]
    je   .push                       ; eating: the tail stays, so the snake grows
    mov  byte [rsi+r10], 0
    inc  dword [tail]
.push:
    mov  byte [rsi+r9], 1
    mov  eax, [head]
    and  eax, 511
    mov  [rdi+rax*4], r9d
    inc  dword [head]
    mov  [hx], edx
    mov  [hy], r8d
    cmp  r9d, [food]
    jne  .ret
    mov  eax, [score]
    inc  eax
    mov  [score], eax
    cmp  eax, [best]
    jbe  .nb
    mov  [best], eax
.nb:
    mov  eax, [dir]                  ; eat kick: push the WINDOW 10 pixels the way we move
    lea  rsi, [dxt]
    mov  ecx, [rsi+rax*4]
    imul ecx, ecx, 10
    mov  [kx], ecx
    lea  rsi, [dyt]
    mov  ecx, [rsi+rax*4]
    imul ecx, ecx, 10
    mov  [ky], ecx
    jmp  placefood
.dead:
    mov  dword [state], 1
    mov  dword [amp], 20             ; crash: shake the window for 20 animation frames
.ret:
    ret

; =========================================================
;  DRAWING (pure CPU: everything is stores into `buffer`)
; =========================================================

; fillrect: ecx=x, edx=y, r8d=width, r9d=height, eax=color
; clobbers rcx, rdx, rdi, r9
fillrect:
    imul edx, edx, W
    add  edx, ecx                    ; pixel index = y*W + x
    lea  rdi, [buffer]
    lea  rdi, [rdi+rdx*4]            ; 4 bytes per pixel
.line:
    push rdi
    mov  ecx, r8d
    rep  stosd
    pop  rdi
    add  rdi, W*4                    ; next row
    dec  r9d
    jnz  .line
    ret

; blk: like fillrect but a square relative to a cell origin
; r10d,r11d = origin, ecx,edx = offset, r8d = size, eax = color
blk:
    add  ecx, r10d
    add  edx, r11d
    mov  r9d, r8d
    jmp  fillrect

; cellorigin: eax = cell -> r10d,r11d = pixel position, r9d = gx+gy
cellorigin:
    xor  edx, edx
    mov  ecx, GW
    div  ecx                         ; eax = y, edx = x
    lea  r9d, [rax+rdx]
    imul r10d, edx, CELL
    imul r11d, eax, CELL
    add  r11d, TOP
    ret

; drawcuts: r9d = color. Two accent lines, 2 pixels thick, just inside
; the diagonal edges of the cut corners (top-left and bottom-right).
; Pixel math only, no fillrect. clobbers rax, rdi, r10
drawcuts:
    lea  rdi, [buffer]
    xor  r10d, r10d
.dl:
    mov  eax, CUT+1                  ; top-left: (i, K-i) for K = CUT+1 and CUT+2
    sub  eax, r10d
    imul eax, eax, W
    add  eax, r10d
    mov  [rdi+rax*4], r9d
    mov  eax, CUT+2
    sub  eax, r10d
    imul eax, eax, W
    add  eax, r10d
    mov  [rdi+rax*4], r9d
    lea  eax, [r10+H-1-(CUT+1)]      ; bottom-right: (W-1-i, H-1-K+i)
    imul eax, eax, W
    add  eax, W-1
    sub  eax, r10d
    mov  [rdi+rax*4], r9d
    lea  eax, [r10+H-1-(CUT+2)]
    imul eax, eax, W
    add  eax, W-1
    sub  eax, r10d
    mov  [rdi+rax*4], r9d
    inc  r10d
    cmp  r10d, CUT+2
    jb   .dl
    ret

; num3: eax = value (0..999), rdi = 3 characters to write
num3:
    xor  edx, edx
    mov  ecx, 100
    div  ecx
    add  al, '0'
    mov  [rdi], al
    mov  eax, edx
    xor  edx, edx
    mov  ecx, 10
    div  ecx
    add  al, '0'
    add  dl, '0'
    mov  [rdi+1], al
    mov  [rdi+2], dl
    ret

; drawtext: rsi = zero-terminated string, r12d = x, r13d = y,
;           r14d = pixel scale, r15d = color.  3x5 bitmap font.
; clobbers rax, rbx, rcx, rdx, rdi, r8-r11, r12
drawtext:
.char:
    movzx eax, byte [rsi]
    inc  rsi
    test eax, eax
    jz   .done
    sub  eax, '0'
    jb   .adv                        ; space etc.: just advance
    cmp  eax, 42                     ; '0'..'Z'
    ja   .adv
    lea  rdx, [font]
    lea  eax, [rax+rax*4]            ; 5 bytes per glyph
    lea  rbx, [rdx+rax]              ; RBX = glyph rows
    xor  r10d, r10d                  ; row 0..4
.row:
    xor  r11d, r11d                  ; column 0..2
.col:
    movzx edx, byte [rbx+r10]
    mov  ecx, 2
    sub  ecx, r11d
    bt   edx, ecx                    ; is this pixel of the glyph set?
    jnc  .skip
    mov  eax, r11d
    imul eax, r14d
    lea  ecx, [r12+rax]              ; x + col*scale
    mov  eax, r10d
    imul eax, r14d
    lea  edx, [r13+rax]              ; y + row*scale
    mov  r8d, r14d
    mov  r9d, r14d
    mov  eax, r15d
    call fillrect
.skip:
    inc  r11d
    cmp  r11d, 3
    jb   .col
    inc  r10d
    cmp  r10d, 5
    jb   .row
.adv:
    lea  eax, [r14+r14*2]
    add  eax, r14d                   ; advance = 4 * scale (3 pixels + 1 gap)
    add  r12d, eax
    jmp  .char
.done:
    ret

; ---------------------------------------------------------
render:                              ; draws the complete frame into `buffer`
    mov  eax, COL_TITLE              ; --- title bar
    xor  ecx, ecx
    xor  edx, edx
    mov  r8d, W
    mov  r9d, TOP
    call fillrect

    xor  ebx, ebx                    ; --- checkerboard playfield
.chk:
    mov  eax, ebx
    call cellorigin
    mov  eax, COL_A
    test r9b, 1
    jz   .c1
    mov  eax, COL_B
.c1:
    xor  ecx, ecx
    xor  edx, edx
    mov  r8d, CELL
    call blk
    inc  ebx
    cmp  ebx, GW*GH
    jb   .chk

    mov  eax, [food]                 ; --- food
    call cellorigin
    mov  eax, COL_FOOD
    mov  ecx, 3
    mov  edx, 3
    mov  r8d, 14
    call blk
    mov  eax, COL_FOODHI
    mov  ecx, 5
    mov  edx, 5
    mov  r8d, 4
    call blk

    mov  dword [colbody],  0x002E9E5B    ; --- snake colors (red-ish when dead)
    mov  dword [colinner], 0x0040C474
    mov  dword [colhead],  COL_GREEN
    cmp  dword [state], 1
    jne  .alive
    mov  dword [colbody],  0x00803848
    mov  dword [colinner], 0x00A04458
    mov  dword [colhead],  0x00D05A70
.alive:
    mov  ebx, [tail]                 ; --- snake: walk the queue from tail to head
.sn:
    cmp  ebx, [head]
    jae  .sndone
    mov  eax, ebx
    and  eax, 511
    lea  rcx, [queue]
    mov  eax, [rcx+rax*4]
    call cellorigin
    mov  eax, [colbody]
    mov  ecx, 1
    mov  edx, 1
    mov  r8d, 18
    call blk
    mov  eax, [colinner]
    mov  ecx, 5
    mov  edx, 5
    mov  r8d, 10
    call blk
    lea  eax, [rbx+1]
    cmp  eax, [head]
    jne  .nexts                      ; only the last segment is the head
    mov  eax, [colhead]
    mov  ecx, 1
    mov  edx, 1
    mov  r8d, 18
    call blk
    mov  eax, [dir]                  ; eyes depend on the direction
    lea  rsi, [eyes]
    lea  rsi, [rsi+rax*4]
    movzx ecx, byte [rsi]
    movzx edx, byte [rsi+1]
    mov  r8d, 4
    mov  eax, COL_EYE
    call blk
    movzx ecx, byte [rsi+2]
    movzx edx, byte [rsi+3]
    mov  r8d, 4
    mov  eax, COL_EYE
    call blk
.nexts:
    inc  ebx
    jmp  .sn
.sndone:

    lea  rsi, [title]                ; --- title bar text
    mov  r12d, 26
    mov  r13d, 10
    mov  r14d, 2
    mov  r15d, COL_TEXT
    call drawtext
    mov  eax, [score]
    lea  rdi, [scorestr+6]
    call num3
    lea  rsi, [scorestr]
    mov  r12d, 96
    mov  r13d, 10
    call drawtext
    mov  eax, [best]
    lea  rdi, [beststr+5]
    call num3
    lea  rsi, [beststr]
    mov  r12d, 186
    mov  r13d, 10
    mov  r15d, COL_DIM
    call drawtext
    cmp  dword [topmost], 0          ; green TOP tag while always-on-top is on
    je   .notop
    lea  rsi, [topstr]
    mov  r12d, 270
    mov  r13d, 10
    mov  r15d, COL_GREEN
    call drawtext
.notop:

    mov  eax, COL_CLOSE              ; --- close button with a hand-drawn X
    mov  ecx, 360
    xor  edx, edx
    mov  r8d, 40
    mov  r9d, TOP-1
    call fillrect
    lea  rdi, [buffer]
    xor  r10d, r10d
.xl:
    lea  eax, [r10+9]                ; first diagonal: (373+i, 9+i)
    imul eax, eax, W
    lea  eax, [rax+r10+373]
    mov  dword [rdi+rax*4],   COL_WHITE
    mov  dword [rdi+rax*4+4], COL_WHITE
    mov  edx, 20                     ; second diagonal: (373+i, 20-i)
    sub  edx, r10d
    imul edx, edx, W
    lea  edx, [rdx+r10+373]
    mov  dword [rdi+rdx*4],   COL_WHITE
    mov  dword [rdi+rdx*4+4], COL_WHITE
    inc  r10d
    cmp  r10d, 12
    jb   .xl

    cmp  dword [state], 0            ; --- message panel (ready / game over)
    je   .noov
    mov  eax, COL_FOOD
    cmp  dword [state], 1
    je   .acc
    mov  eax, COL_GREEN
.acc:
    mov  ecx, 90
    mov  edx, 125
    mov  r8d, 220
    mov  r9d, 72
    call fillrect
    mov  eax, COL_PANEL
    mov  ecx, 92
    mov  edx, 127
    mov  r8d, 216
    mov  r9d, 68
    call fillrect
    mov  r13d, 137
    mov  r14d, 4
    mov  r15d, COL_TEXT
    cmp  dword [state], 1
    jne  .rdy
    lea  rsi, [overstr]
    mov  r12d, 130
    jmp  .hl
.rdy:
    lea  rsi, [title]
    mov  r12d, 162
.hl:
    call drawtext
    lea  rsi, [hintstr]
    mov  r12d, 157
    mov  r13d, 173
    mov  r14d, 2
    mov  r15d, COL_DIM
    call drawtext
.noov:

    mov  eax, COL_BORDER             ; --- 1 pixel border + title separator
    xor  ecx, ecx
    xor  edx, edx
    mov  r8d, W
    mov  r9d, 1
    call fillrect
    xor  ecx, ecx
    mov  edx, H-1
    mov  r8d, W
    mov  r9d, 1
    call fillrect
    xor  ecx, ecx
    xor  edx, edx
    mov  r8d, 1
    mov  r9d, H
    call fillrect
    mov  ecx, W-1
    xor  edx, edx
    mov  r8d, 1
    mov  r9d, H
    call fillrect
    xor  ecx, ecx
    mov  edx, TOP-1
    mov  r8d, W
    mov  r9d, 1
    call fillrect

    mov  r9d, COL_GREEN              ; --- accent outline (red when dead)
    cmp  dword [state], 1
    jne  .accent
    mov  r9d, COL_FOOD
.accent:
    call drawcuts                    ; glowing lines along the cut corners (keeps r9d)
    mov  eax, r9d
    mov  ecx, CUT+6                  ; short accent underline below the title
    mov  edx, TOP-1
    mov  r8d, 60
    mov  r9d, 1
    call fillrect
    ret

; =========================================================
section '.data' data readable writeable

classname db 'SnakeRaw2', 0
title     db 'SNAKE', 0
overstr   db 'GAME OVER', 0
hintstr   db 'PRESS SPACE', 0
scorestr  db 'SCORE 000', 0
beststr   db 'BEST 000', 0
topstr    db 'TOP', 0

keytab db 0x26,0x57, 0x27,0x44, 0x28,0x53, 0x25,0x41   ; up/W right/D down/S left/A
dxt    dd 0, 1, 0, -1                                    ; direction -> dx
dyt    dd -1, 0, 1, 0                                    ; direction -> dy
eyes   db 4,4,12,4,  12,4,12,12,  4,12,12,12,  4,4,4,12 ; eye positions per direction

; window outline: top-left and bottom-right corners are cut off
poly   dd CUT,0,  W,0,  W,H-CUT,  W-CUT,H,  0,H,  0,CUT

; 3x5 bitmap font for the characters '0'..'Z' (5 rows per glyph, 3 bits per row)
font:
  db 111b,101b,101b,101b,111b          ; 0
  db 010b,110b,010b,010b,111b          ; 1
  db 111b,001b,111b,100b,111b          ; 2
  db 111b,001b,111b,001b,111b          ; 3
  db 101b,101b,111b,001b,001b          ; 4
  db 111b,100b,111b,001b,111b          ; 5
  db 111b,100b,111b,101b,111b          ; 6
  db 111b,001b,001b,001b,001b          ; 7
  db 111b,101b,111b,101b,111b          ; 8
  db 111b,101b,111b,001b,111b          ; 9
  db 7*5 dup 0                         ; : ; < = > ? @
  db 010b,101b,111b,101b,101b          ; A
  db 110b,101b,110b,101b,110b          ; B
  db 111b,100b,100b,100b,111b          ; C
  db 5 dup 0                           ; D
  db 111b,100b,111b,100b,111b          ; E
  db 5 dup 0                           ; F
  db 111b,100b,101b,101b,111b          ; G
  db 3*5 dup 0                         ; H I J
  db 101b,101b,110b,101b,101b          ; K
  db 5 dup 0                           ; L
  db 101b,111b,111b,101b,101b          ; M
  db 111b,101b,101b,101b,101b          ; N
  db 111b,101b,101b,101b,111b          ; O
  db 111b,101b,111b,100b,100b          ; P
  db 5 dup 0                           ; Q
  db 110b,101b,110b,101b,101b          ; R
  db 111b,100b,111b,001b,111b          ; S
  db 111b,010b,010b,010b,010b          ; T
  db 5 dup 0                           ; U
  db 101b,101b,101b,101b,010b          ; V
  db 4*5 dup 0                         ; W X Y Z

bmi:                                 ; BITMAPINFOHEADER
    dd 40                            ; header size
    dd W                             ; width
    dd -H                            ; negative = top row first in memory
    dw 1                             ; planes
    dw 32                            ; bits per pixel (B, G, R, unused)
    dd 0, 0, 0, 0, 0, 0

; game state
seed     dd 1
food     dd 0
hx       dd 0
hy       dd 0
dir      dd 1
nextdir  dd 1
head     dd 0
tail     dd 0
score    dd 0
best     dd 0
state    dd 2
colbody  dd 0
colinner dd 0
colhead  dd 0

; window-effect state
alpha    dd 0                        ; current opacity 0..255 (starts invisible)
target   dd 255                      ; opacity we are fading toward
quitting dd 0                        ; 1 = fading out, then quit
topmost  dd 0                        ; 1 = always on top
amp      dd 0                        ; shake strength in pixels (counts down)
kx       dd 0                        ; eat kick, decays to 0
ky       dd 0
ox       dd 0                        ; window offset we have applied so far
oy       dd 0

grid   rb GW*GH                      ; 300 bytes
queue  rd 512                        ; snake cells (ring buffer)
buffer rb W*H*4                      ; the framebuffer: 528,000 bytes

section '.idata' import data readable writeable
library kernel32, 'KERNEL32.DLL', \
        user32,   'USER32.DLL',   \
        gdi32,    'GDI32.DLL'
import kernel32, GetModuleHandleA, 'GetModuleHandleA', \
                 ExitProcess,      'ExitProcess'
import user32, LoadCursorA,                'LoadCursorA',                \
               RegisterClassExA,           'RegisterClassExA',           \
               CreateWindowExA,            'CreateWindowExA',            \
               SetLayeredWindowAttributes, 'SetLayeredWindowAttributes', \
               SetWindowRgn,               'SetWindowRgn',               \
               SetWindowPos,               'SetWindowPos',               \
               GetWindowRect,              'GetWindowRect',              \
               SetTimer,                   'SetTimer',                   \
               SetForegroundWindow,        'SetForegroundWindow',        \
               GetMessageA,                'GetMessageA',                \
               DispatchMessageA,           'DispatchMessageA',           \
               DefWindowProcA,             'DefWindowProcA',             \
               PostQuitMessage,            'PostQuitMessage',            \
               BeginPaint,                 'BeginPaint',                 \
               EndPaint,                   'EndPaint',                   \
               InvalidateRect,             'InvalidateRect',             \
               ReleaseCapture,             'ReleaseCapture',             \
               SendMessageA,               'SendMessageA'
import gdi32, SetDIBitsToDevice, 'SetDIBitsToDevice', \
              CreatePolygonRgn,  'CreatePolygonRgn'