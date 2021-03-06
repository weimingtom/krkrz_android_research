;
; jdmerss2.asm - merged upsampling/color conversion (SSE2)
;
; x86 SIMD extension for IJG JPEG library
; Copyright (C) 1999-2006, MIYASAKA Masaru.
; For conditions of distribution and use, see copyright notice in jsimdext.inc
;
; This file should be assembled with NASM (Netwide Assembler),
; can *not* be assembled with Microsoft's MASM or any compatible
; assembler (including Borland's Turbo Assembler).
; NASM is available from http://nasm.sourceforge.net/ or
; http://sourceforge.net/project/showfiles.php?group_id=6208
;
; Last Modified : February 4, 2006
;
; [TAB8]

%include "jsimdext.inc"
%include "jcolsamp.inc"

%if RGB_PIXELSIZE == 3 || RGB_PIXELSIZE == 4
%ifdef UPSAMPLE_MERGING_SUPPORTED
%ifdef JDMERGE_SSE2_SUPPORTED

; --------------------------------------------------------------------------

%define SCALEBITS	16

F_0_344	equ	 22554			; FIX(0.34414)
F_0_714	equ	 46802			; FIX(0.71414)
F_1_402	equ	 91881			; FIX(1.40200)
F_1_772	equ	116130			; FIX(1.77200)
F_0_402	equ	(F_1_402 - 65536)	; FIX(1.40200) - FIX(1)
F_0_285	equ	( 65536 - F_0_714)	; FIX(1) - FIX(0.71414)
F_0_228	equ	(131072 - F_1_772)	; FIX(2) - FIX(1.77200)

; --------------------------------------------------------------------------
	SECTION	SEG_CONST

	alignz	16
	global	EXTN(jconst_merged_upsample_sse2)

EXTN(jconst_merged_upsample_sse2):

PW_F0402	times 8 dw  F_0_402
PW_MF0228	times 8 dw -F_0_228
PW_MF0344_F0285	times 4 dw -F_0_344, F_0_285
PW_ONE		times 8 dw  1
PD_ONEHALF	times 4 dd  1 << (SCALEBITS-1)

	alignz	16

; --------------------------------------------------------------------------
	SECTION	SEG_TEXT
	BITS	32
;
; Upsample and color convert for the case of 2:1 horizontal and 1:1 vertical.
;
; GLOBAL(void)
; jpeg_h2v1_merged_upsample_sse2 (j_decompress_ptr cinfo, JSAMPIMAGE input_buf,
;                                 JDIMENSION in_row_group_ctr,
;                                 JSAMPARRAY output_buf);
;

%define cinfo(b)		(b)+8		; j_decompress_ptr cinfo
%define input_buf(b)		(b)+12		; JSAMPIMAGE input_buf
%define in_row_group_ctr(b)	(b)+16		; JDIMENSION in_row_group_ctr
%define output_buf(b)		(b)+20		; JSAMPARRAY output_buf

%define original_ebp	ebp+0
%define wk(i)		ebp-(WK_NUM-(i))*SIZEOF_XMMWORD	; xmmword wk[WK_NUM]
%define WK_NUM		3
%define gotptr		wk(0)-SIZEOF_POINTER	; void * gotptr

	align	16
	global	EXTN(jpeg_h2v1_merged_upsample_sse2)

EXTN(jpeg_h2v1_merged_upsample_sse2):
	push	ebp
	mov	eax,esp				; eax = original ebp
	sub	esp, byte 4
	and	esp, byte (-SIZEOF_XMMWORD)	; align to 128 bits
	mov	[esp],eax
	mov	ebp,esp				; ebp = aligned ebp
	lea	esp, [wk(0)]
	pushpic	eax		; make a room for GOT address
	push	ebx
;	push	ecx		; need not be preserved
;	push	edx		; need not be preserved
	push	esi
	push	edi

	get_GOT	ebx			; get GOT address
	movpic	POINTER [gotptr], ebx	; save GOT address

	mov	ecx, POINTER [cinfo(eax)]
	mov	ecx, JDIMENSION [jdstruct_output_width(ecx)]	; col
	test	ecx,ecx
	jz	near .return

	push	ecx

	mov	edi, JSAMPIMAGE [input_buf(eax)]
	mov	ecx, JDIMENSION [in_row_group_ctr(eax)]
	mov	esi, JSAMPARRAY [edi+0*SIZEOF_JSAMPARRAY]
	mov	ebx, JSAMPARRAY [edi+1*SIZEOF_JSAMPARRAY]
	mov	edx, JSAMPARRAY [edi+2*SIZEOF_JSAMPARRAY]
	mov	edi, JSAMPARRAY [output_buf(eax)]
	mov	esi, JSAMPROW [esi+ecx*SIZEOF_JSAMPROW]		; inptr0
	mov	ebx, JSAMPROW [ebx+ecx*SIZEOF_JSAMPROW]		; inptr1
	mov	edx, JSAMPROW [edx+ecx*SIZEOF_JSAMPROW]		; inptr2
	mov	edi, JSAMPROW [edi]				; outptr

	pop	ecx			; col

	alignx	16,7
.columnloop:
	movpic	eax, POINTER [gotptr]	; load GOT address (eax)

	movdqa    xmm6, XMMWORD [ebx]	; xmm6=Cb(0123456789ABCDEF)
	movdqa    xmm7, XMMWORD [edx]	; xmm7=Cr(0123456789ABCDEF)

	pxor      xmm1,xmm1		; xmm1=(all 0's)
	pcmpeqw   xmm3,xmm3
	psllw     xmm3,7		; xmm3={0xFF80 0xFF80 0xFF80 0xFF80 ..}

	movdqa    xmm4,xmm6
	punpckhbw xmm6,xmm1		; xmm6=Cb(89ABCDEF)=CbH
	punpcklbw xmm4,xmm1		; xmm4=Cb(01234567)=CbL
	movdqa    xmm0,xmm7
	punpckhbw xmm7,xmm1		; xmm7=Cr(89ABCDEF)=CrH
	punpcklbw xmm0,xmm1		; xmm0=Cr(01234567)=CrL

	paddw     xmm6,xmm3
	paddw     xmm4,xmm3
	paddw     xmm7,xmm3
	paddw     xmm0,xmm3

	; (Original)
	; R = Y                + 1.40200 * Cr
	; G = Y - 0.34414 * Cb - 0.71414 * Cr
	; B = Y + 1.77200 * Cb
	;
	; (This implementation)
	; R = Y                + 0.40200 * Cr + Cr
	; G = Y - 0.34414 * Cb + 0.28586 * Cr - Cr
	; B = Y - 0.22800 * Cb + Cb + Cb

	movdqa	xmm5,xmm6		; xmm5=CbH
	movdqa	xmm2,xmm4		; xmm2=CbL
	paddw	xmm6,xmm6		; xmm6=2*CbH
	paddw	xmm4,xmm4		; xmm4=2*CbL
	movdqa	xmm1,xmm7		; xmm1=CrH
	movdqa	xmm3,xmm0		; xmm3=CrL
	paddw	xmm7,xmm7		; xmm7=2*CrH
	paddw	xmm0,xmm0		; xmm0=2*CrL

	pmulhw	xmm6,[GOTOFF(eax,PW_MF0228)]	; xmm6=(2*CbH * -FIX(0.22800))
	pmulhw	xmm4,[GOTOFF(eax,PW_MF0228)]	; xmm4=(2*CbL * -FIX(0.22800))
	pmulhw	xmm7,[GOTOFF(eax,PW_F0402)]	; xmm7=(2*CrH * FIX(0.40200))
	pmulhw	xmm0,[GOTOFF(eax,PW_F0402)]	; xmm0=(2*CrL * FIX(0.40200))

	paddw	xmm6,[GOTOFF(eax,PW_ONE)]
	paddw	xmm4,[GOTOFF(eax,PW_ONE)]
	psraw	xmm6,1			; xmm6=(CbH * -FIX(0.22800))
	psraw	xmm4,1			; xmm4=(CbL * -FIX(0.22800))
	paddw	xmm7,[GOTOFF(eax,PW_ONE)]
	paddw	xmm0,[GOTOFF(eax,PW_ONE)]
	psraw	xmm7,1			; xmm7=(CrH * FIX(0.40200))
	psraw	xmm0,1			; xmm0=(CrL * FIX(0.40200))

	paddw	xmm6,xmm5
	paddw	xmm4,xmm2
	paddw	xmm6,xmm5		; xmm6=(CbH * FIX(1.77200))=(B-Y)H
	paddw	xmm4,xmm2		; xmm4=(CbL * FIX(1.77200))=(B-Y)L
	paddw	xmm7,xmm1		; xmm7=(CrH * FIX(1.40200))=(R-Y)H
	paddw	xmm0,xmm3		; xmm0=(CrL * FIX(1.40200))=(R-Y)L

	movdqa	XMMWORD [wk(0)], xmm6	; wk(0)=(B-Y)H
	movdqa	XMMWORD [wk(1)], xmm7	; wk(1)=(R-Y)H

	movdqa    xmm6,xmm5
	movdqa    xmm7,xmm2
	punpcklwd xmm5,xmm1
	punpckhwd xmm6,xmm1
	pmaddwd   xmm5,[GOTOFF(eax,PW_MF0344_F0285)]
	pmaddwd   xmm6,[GOTOFF(eax,PW_MF0344_F0285)]
	punpcklwd xmm2,xmm3
	punpckhwd xmm7,xmm3
	pmaddwd   xmm2,[GOTOFF(eax,PW_MF0344_F0285)]
	pmaddwd   xmm7,[GOTOFF(eax,PW_MF0344_F0285)]

	paddd     xmm5,[GOTOFF(eax,PD_ONEHALF)]
	paddd     xmm6,[GOTOFF(eax,PD_ONEHALF)]
	psrad     xmm5,SCALEBITS
	psrad     xmm6,SCALEBITS
	paddd     xmm2,[GOTOFF(eax,PD_ONEHALF)]
	paddd     xmm7,[GOTOFF(eax,PD_ONEHALF)]
	psrad     xmm2,SCALEBITS
	psrad     xmm7,SCALEBITS

	packssdw  xmm5,xmm6	; xmm5=CbH*-FIX(0.344)+CrH*FIX(0.285)
	packssdw  xmm2,xmm7	; xmm2=CbL*-FIX(0.344)+CrL*FIX(0.285)
	psubw     xmm5,xmm1	; xmm5=CbH*-FIX(0.344)+CrH*-FIX(0.714)=(G-Y)H
	psubw     xmm2,xmm3	; xmm2=CbL*-FIX(0.344)+CrL*-FIX(0.714)=(G-Y)L

	movdqa	XMMWORD [wk(2)], xmm5	; wk(2)=(G-Y)H

	mov	al,2			; Yctr
	jmp	short .Yloop_1st
	alignx	16,7

.Yloop_2nd:
	movdqa	xmm0, XMMWORD [wk(1)]	; xmm0=(R-Y)H
	movdqa	xmm2, XMMWORD [wk(2)]	; xmm2=(G-Y)H
	movdqa	xmm4, XMMWORD [wk(0)]	; xmm4=(B-Y)H
	alignx	16,7

.Yloop_1st:
	movdqa	xmm7, XMMWORD [esi]	; xmm7=Y(0123456789ABCDEF)

	pcmpeqw	xmm6,xmm6
	psrlw	xmm6,BYTE_BIT		; xmm6={0xFF 0x00 0xFF 0x00 ..}
	pand	xmm6,xmm7		; xmm6=Y(02468ACE)=YE
	psrlw	xmm7,BYTE_BIT		; xmm7=Y(13579BDF)=YO

	movdqa	xmm1,xmm0		; xmm1=xmm0=(R-Y)(L/H)
	movdqa	xmm3,xmm2		; xmm3=xmm2=(G-Y)(L/H)
	movdqa	xmm5,xmm4		; xmm5=xmm4=(B-Y)(L/H)

	paddw     xmm0,xmm6		; xmm0=((R-Y)+YE)=RE=R(02468ACE)
	paddw     xmm1,xmm7		; xmm1=((R-Y)+YO)=RO=R(13579BDF)
	packuswb  xmm0,xmm0		; xmm0=R(02468ACE********)
	packuswb  xmm1,xmm1		; xmm1=R(13579BDF********)

	paddw     xmm2,xmm6		; xmm2=((G-Y)+YE)=GE=G(02468ACE)
	paddw     xmm3,xmm7		; xmm3=((G-Y)+YO)=GO=G(13579BDF)
	packuswb  xmm2,xmm2		; xmm2=G(02468ACE********)
	packuswb  xmm3,xmm3		; xmm3=G(13579BDF********)

	paddw     xmm4,xmm6		; xmm4=((B-Y)+YE)=BE=B(02468ACE)
	paddw     xmm5,xmm7		; xmm5=((B-Y)+YO)=BO=B(13579BDF)
	packuswb  xmm4,xmm4		; xmm4=B(02468ACE********)
	packuswb  xmm5,xmm5		; xmm5=B(13579BDF********)

%if RGB_PIXELSIZE == 3 ; ---------------

	; xmmA=(00 02 04 06 08 0A 0C 0E **), xmmB=(01 03 05 07 09 0B 0D 0F **)
	; xmmC=(10 12 14 16 18 1A 1C 1E **), xmmD=(11 13 15 17 19 1B 1D 1F **)
	; xmmE=(20 22 24 26 28 2A 2C 2E **), xmmF=(21 23 25 27 29 2B 2D 2F **)
	; xmmG=(** ** ** ** ** ** ** ** **), xmmH=(** ** ** ** ** ** ** ** **)

	punpcklbw xmmA,xmmC	; xmmA=(00 10 02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E)
	punpcklbw xmmE,xmmB	; xmmE=(20 01 22 03 24 05 26 07 28 09 2A 0B 2C 0D 2E 0F)
	punpcklbw xmmD,xmmF	; xmmD=(11 21 13 23 15 25 17 27 19 29 1B 2B 1D 2D 1F 2F)

	movdqa    xmmG,xmmA
	movdqa    xmmH,xmmA
	punpcklwd xmmA,xmmE	; xmmA=(00 10 20 01 02 12 22 03 04 14 24 05 06 16 26 07)
	punpckhwd xmmG,xmmE	; xmmG=(08 18 28 09 0A 1A 2A 0B 0C 1C 2C 0D 0E 1E 2E 0F)

	psrldq    xmmH,2	; xmmH=(02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E -- --)
	psrldq    xmmE,2	; xmmE=(22 03 24 05 26 07 28 09 2A 0B 2C 0D 2E 0F -- --)

	movdqa    xmmC,xmmD
	movdqa    xmmB,xmmD
	punpcklwd xmmD,xmmH	; xmmD=(11 21 02 12 13 23 04 14 15 25 06 16 17 27 08 18)
	punpckhwd xmmC,xmmH	; xmmC=(19 29 0A 1A 1B 2B 0C 1C 1D 2D 0E 1E 1F 2F -- --)

	psrldq    xmmB,2	; xmmB=(13 23 15 25 17 27 19 29 1B 2B 1D 2D 1F 2F -- --)

	movdqa    xmmF,xmmE
	punpcklwd xmmE,xmmB	; xmmE=(22 03 13 23 24 05 15 25 26 07 17 27 28 09 19 29)
	punpckhwd xmmF,xmmB	; xmmF=(2A 0B 1B 2B 2C 0D 1D 2D 2E 0F 1F 2F -- -- -- --)

	pshufd    xmmH,xmmA,0x4E; xmmH=(04 14 24 05 06 16 26 07 00 10 20 01 02 12 22 03)
	movdqa    xmmB,xmmE
	punpckldq xmmA,xmmD	; xmmA=(00 10 20 01 11 21 02 12 02 12 22 03 13 23 04 14)
	punpckldq xmmE,xmmH	; xmmE=(22 03 13 23 04 14 24 05 24 05 15 25 06 16 26 07)
	punpckhdq xmmD,xmmB	; xmmD=(15 25 06 16 26 07 17 27 17 27 08 18 28 09 19 29)

	pshufd    xmmH,xmmG,0x4E; xmmH=(0C 1C 2C 0D 0E 1E 2E 0F 08 18 28 09 0A 1A 2A 0B)
	movdqa    xmmB,xmmF
	punpckldq xmmG,xmmC	; xmmG=(08 18 28 09 19 29 0A 1A 0A 1A 2A 0B 1B 2B 0C 1C)
	punpckldq xmmF,xmmH	; xmmF=(2A 0B 1B 2B 0C 1C 2C 0D 2C 0D 1D 2D 0E 1E 2E 0F)
	punpckhdq xmmC,xmmB	; xmmC=(1D 2D 0E 1E 2E 0F 1F 2F 1F 2F -- -- -- -- -- --)

	punpcklqdq xmmA,xmmE	; xmmA=(00 10 20 01 11 21 02 12 22 03 13 23 04 14 24 05)
	punpcklqdq xmmD,xmmG	; xmmD=(15 25 06 16 26 07 17 27 08 18 28 09 19 29 0A 1A)
	punpcklqdq xmmF,xmmC	; xmmF=(2A 0B 1B 2B 0C 1C 2C 0D 1D 2D 0E 1E 2E 0F 1F 2F)

	cmp	ecx, byte SIZEOF_XMMWORD
	jb	short .column_st32

	test	edi, SIZEOF_XMMWORD-1
	jnz	short .out1
	; --(aligned)-------------------
	movntdq	XMMWORD [edi+0*SIZEOF_XMMWORD], xmmA
	movntdq	XMMWORD [edi+1*SIZEOF_XMMWORD], xmmD
	movntdq	XMMWORD [edi+2*SIZEOF_XMMWORD], xmmF
	add	edi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr
	jmp	short .out0
.out1:	; --(unaligned)-----------------
	pcmpeqb    xmmH,xmmH			; xmmH=(all 1's)
	maskmovdqu xmmA,xmmH			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmD,xmmH			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmF,xmmH			; movntdqu XMMWORD [edi], xmmF
	add	edi, byte SIZEOF_XMMWORD	; outptr
.out0:
	sub	ecx, byte SIZEOF_XMMWORD
	jz	near .endcolumn

	add	esi, byte SIZEOF_XMMWORD	; inptr0
	dec	al			; Yctr
	jnz	near .Yloop_2nd

	add	ebx, byte SIZEOF_XMMWORD	; inptr1
	add	edx, byte SIZEOF_XMMWORD	; inptr2
	jmp	near .columnloop
	alignx	16,7

.column_st32:
	pcmpeqb	xmmH,xmmH			; xmmH=(all 1's)
	lea	ecx, [ecx+ecx*2]		; imul ecx, RGB_PIXELSIZE
	cmp	ecx, byte 2*SIZEOF_XMMWORD
	jb	short .column_st16
	maskmovdqu xmmA,xmmH			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmD,xmmH			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr
	movdqa	xmmA,xmmF
	sub	ecx, byte 2*SIZEOF_XMMWORD
	jmp	short .column_st15
.column_st16:
	cmp	ecx, byte SIZEOF_XMMWORD
	jb	short .column_st15
	maskmovdqu xmmA,xmmH			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	movdqa	xmmA,xmmD
	sub	ecx, byte SIZEOF_XMMWORD
.column_st15:
	mov	eax,ecx
	xor	ecx, byte 0x0F
	shl	ecx, 2
	movd	xmmB,ecx
	psrlq	xmmH,4
	pcmpeqb	xmmE,xmmE
	psrlq	xmmH,xmmB
	psrlq	xmmE,xmmB
	punpcklbw xmmE,xmmH
	; ----------------
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0
	add	eax,ecx
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmA,ecx & pslldq xmmE,ecx
	movdqa	xmmG,xmmA
	movdqa	xmmC,xmmE
	pslldq	xmmA, SIZEOF_XMMWORD/2
	pslldq	xmmE, SIZEOF_XMMWORD/2
	movd	xmmD,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1
	movd	xmmF,ecx
	psllq	xmmA,xmmF
	psllq	xmmE,xmmF
	jmp	short .adj0
.adj1:	neg	ecx
	movd	xmmF,ecx
	psrlq	xmmA,xmmF
	psrlq	xmmE,xmmF
	psllq	xmmG,xmmD
	psllq	xmmC,xmmD
	por	xmmA,xmmG
	por	xmmE,xmmC
.adj0:	; ----------------
	maskmovdqu xmmA,xmmE			; movntdqu XMMWORD [edi], xmmA

%else ; RGB_PIXELSIZE == 4 ; -----------

%ifdef RGBX_FILLER_0XFF
	pcmpeqb   xmm6,xmm6		; xmm6=XE=X(02468ACE********)
	pcmpeqb   xmm7,xmm7		; xmm7=XO=X(13579BDF********)
%else
	pxor      xmm6,xmm6		; xmm6=XE=X(02468ACE********)
	pxor      xmm7,xmm7		; xmm7=XO=X(13579BDF********)
%endif
	; xmmA=(00 02 04 06 08 0A 0C 0E **), xmmB=(01 03 05 07 09 0B 0D 0F **)
	; xmmC=(10 12 14 16 18 1A 1C 1E **), xmmD=(11 13 15 17 19 1B 1D 1F **)
	; xmmE=(20 22 24 26 28 2A 2C 2E **), xmmF=(21 23 25 27 29 2B 2D 2F **)
	; xmmG=(30 32 34 36 38 3A 3C 3E **), xmmH=(31 33 35 37 39 3B 3D 3F **)

	punpcklbw xmmA,xmmC	; xmmA=(00 10 02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E)
	punpcklbw xmmE,xmmG	; xmmE=(20 30 22 32 24 34 26 36 28 38 2A 3A 2C 3C 2E 3E)
	punpcklbw xmmB,xmmD	; xmmB=(01 11 03 13 05 15 07 17 09 19 0B 1B 0D 1D 0F 1F)
	punpcklbw xmmF,xmmH	; xmmF=(21 31 23 33 25 35 27 37 29 39 2B 3B 2D 3D 2F 3F)

	movdqa    xmmC,xmmA
	punpcklwd xmmA,xmmE	; xmmA=(00 10 20 30 02 12 22 32 04 14 24 34 06 16 26 36)
	punpckhwd xmmC,xmmE	; xmmC=(08 18 28 38 0A 1A 2A 3A 0C 1C 2C 3C 0E 1E 2E 3E)
	movdqa    xmmG,xmmB
	punpcklwd xmmB,xmmF	; xmmB=(01 11 21 31 03 13 23 33 05 15 25 35 07 17 27 37)
	punpckhwd xmmG,xmmF	; xmmG=(09 19 29 39 0B 1B 2B 3B 0D 1D 2D 3D 0F 1F 2F 3F)

	movdqa    xmmD,xmmA
	punpckldq xmmA,xmmB	; xmmA=(00 10 20 30 01 11 21 31 02 12 22 32 03 13 23 33)
	punpckhdq xmmD,xmmB	; xmmD=(04 14 24 34 05 15 25 35 06 16 26 36 07 17 27 37)
	movdqa    xmmH,xmmC
	punpckldq xmmC,xmmG	; xmmC=(08 18 28 38 09 19 29 39 0A 1A 2A 3A 0B 1B 2B 3B)
	punpckhdq xmmH,xmmG	; xmmH=(0C 1C 2C 3C 0D 1D 2D 3D 0E 1E 2E 3E 0F 1F 2F 3F)

	cmp	ecx, byte SIZEOF_XMMWORD
	jb	short .column_st32

	test	edi, SIZEOF_XMMWORD-1
	jnz	short .out1
	; --(aligned)-------------------
	movntdq	XMMWORD [edi+0*SIZEOF_XMMWORD], xmmA
	movntdq	XMMWORD [edi+1*SIZEOF_XMMWORD], xmmD
	movntdq	XMMWORD [edi+2*SIZEOF_XMMWORD], xmmC
	movntdq	XMMWORD [edi+3*SIZEOF_XMMWORD], xmmH
	add	edi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr
	jmp	short .out0
.out1:	; --(unaligned)-----------------
	pcmpeqb    xmmE,xmmE			; xmmE=(all 1's)
	maskmovdqu xmmA,xmmE			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmD,xmmE			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmC,xmmE			; movntdqu XMMWORD [edi], xmmC
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmH,xmmE			; movntdqu XMMWORD [edi], xmmH
	add	edi, byte SIZEOF_XMMWORD	; outptr
.out0:
	sub	ecx, byte SIZEOF_XMMWORD
	jz	near .endcolumn

	add	esi, byte SIZEOF_XMMWORD	; inptr0
	dec	al			; Yctr
	jnz	near .Yloop_2nd

	add	ebx, byte SIZEOF_XMMWORD	; inptr1
	add	edx, byte SIZEOF_XMMWORD	; inptr2
	jmp	near .columnloop
	alignx	16,7

.column_st32:
	pcmpeqb	xmmE,xmmE			; xmmE=(all 1's)
	cmp	ecx, byte SIZEOF_XMMWORD/2
	jb	short .column_st16
	maskmovdqu xmmA,xmmE			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	maskmovdqu xmmD,xmmE			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr
	movdqa	xmmA,xmmC
	movdqa	xmmD,xmmH
	sub	ecx, byte SIZEOF_XMMWORD/2
.column_st16:
	cmp	ecx, byte SIZEOF_XMMWORD/4
	jb	short .column_st15
	maskmovdqu xmmA,xmmE			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr
	movdqa	xmmA,xmmD
	sub	ecx, byte SIZEOF_XMMWORD/4
.column_st15:
	cmp	ecx, byte SIZEOF_XMMWORD/16
	jb	short .endcolumn
	mov	eax,ecx
	xor	ecx, byte 0x03
	inc	ecx
	shl	ecx, 4
	movd	xmmF,ecx
	psrlq	xmmE,xmmF
	punpcklbw xmmE,xmmE
	; ----------------
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0
	lea	eax, [ecx+eax*4]	; RGB_PIXELSIZE
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmA,ecx & pslldq xmmE,ecx
	movdqa	xmmB,xmmA
	movdqa	xmmG,xmmE
	pslldq	xmmA, SIZEOF_XMMWORD/2
	pslldq	xmmE, SIZEOF_XMMWORD/2
	movd	xmmC,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1
	movd	xmmH,ecx
	psllq	xmmA,xmmH
	psllq	xmmE,xmmH
	jmp	short .adj0
.adj1:	neg	ecx
	movd	xmmH,ecx
	psrlq	xmmA,xmmH
	psrlq	xmmE,xmmH
	psllq	xmmB,xmmC
	psllq	xmmG,xmmC
	por	xmmA,xmmB
	por	xmmE,xmmG
.adj0:	; ----------------
	maskmovdqu xmmA,xmmE			; movntdqu XMMWORD [edi], xmmA

%endif ; RGB_PIXELSIZE ; ---------------

.endcolumn:
	sfence		; flush the write buffer

.return:
	pop	edi
	pop	esi
;	pop	edx		; need not be preserved
;	pop	ecx		; need not be preserved
	pop	ebx
	mov	esp,ebp		; esp <- aligned ebp
	pop	esp		; esp <- original ebp
	pop	ebp
	ret

%ifndef USE_DEDICATED_H2V2_MERGED_UPSAMPLE_SSE2

; --------------------------------------------------------------------------
;
; Upsample and color convert for the case of 2:1 horizontal and 2:1 vertical.
;
; GLOBAL(void)
; jpeg_h2v2_merged_upsample_sse2 (j_decompress_ptr cinfo, JSAMPIMAGE input_buf,
;                                 JDIMENSION in_row_group_ctr,
;                                 JSAMPARRAY output_buf);
;

%define cinfo(b)		(b)+8		; j_decompress_ptr cinfo
%define input_buf(b)		(b)+12		; JSAMPIMAGE input_buf
%define in_row_group_ctr(b)	(b)+16		; JDIMENSION in_row_group_ctr
%define output_buf(b)		(b)+20		; JSAMPARRAY output_buf

	align	16
	global	EXTN(jpeg_h2v2_merged_upsample_sse2)

EXTN(jpeg_h2v2_merged_upsample_sse2):
	push	ebp
	mov	ebp,esp
	push	ebx
;	push	ecx		; need not be preserved
;	push	edx		; need not be preserved
	push	esi
	push	edi

	mov	eax, POINTER [cinfo(ebp)]

	mov	edi, JSAMPIMAGE [input_buf(ebp)]
	mov	ecx, JDIMENSION [in_row_group_ctr(ebp)]
	mov	esi, JSAMPARRAY [edi+0*SIZEOF_JSAMPARRAY]
	mov	ebx, JSAMPARRAY [edi+1*SIZEOF_JSAMPARRAY]
	mov	edx, JSAMPARRAY [edi+2*SIZEOF_JSAMPARRAY]
	mov	edi, JSAMPARRAY [output_buf(ebp)]
	lea	esi, [esi+ecx*SIZEOF_JSAMPROW]

	push	edx			; inptr2
	push	ebx			; inptr1
	push	esi			; inptr00
	mov	ebx,esp

	push	edi			; output_buf (outptr0)
	push	ecx			; in_row_group_ctr
	push	ebx			; input_buf
	push	eax			; cinfo

	call	near EXTN(jpeg_h2v1_merged_upsample_sse2)

	add	esi, byte SIZEOF_JSAMPROW	; inptr01
	add	edi, byte SIZEOF_JSAMPROW	; outptr1
	mov	POINTER [ebx+0*SIZEOF_POINTER], esi
	mov	POINTER [ebx-1*SIZEOF_POINTER], edi

	call	near EXTN(jpeg_h2v1_merged_upsample_sse2)

	add	esp, byte 7*SIZEOF_DWORD

	pop	edi
	pop	esi
;	pop	edx		; need not be preserved
;	pop	ecx		; need not be preserved
	pop	ebx
	pop	ebp
	ret

%else  ; USE_DEDICATED_H2V2_MERGED_UPSAMPLE_SSE2

; --------------------------------------------------------------------------
;
; Upsample and color convert for the case of 2:1 horizontal and 2:1 vertical.
;
; GLOBAL(void)
; jpeg_h2v2_merged_upsample_sse2 (j_decompress_ptr cinfo, JSAMPIMAGE input_buf,
;                                 JDIMENSION in_row_group_ctr,
;                                 JSAMPARRAY output_buf);
;

%define cinfo(b)		(b)+8		; j_decompress_ptr cinfo
%define input_buf(b)		(b)+12		; JSAMPIMAGE input_buf
%define in_row_group_ctr(b)	(b)+16		; JDIMENSION in_row_group_ctr
%define output_buf(b)		(b)+20		; JSAMPARRAY output_buf

%define original_ebp	ebp+0
%define wk(i)		ebp-(WK_NUM-(i))*SIZEOF_XMMWORD	; xmmword wk[WK_NUM]
%define WK_NUM		10
%define inptr1		wk(0)-SIZEOF_JSAMPROW	; JSAMPROW inptr1
%define inptr2		inptr1-SIZEOF_JSAMPROW	; JSAMPROW inptr2
%define gotptr		inptr2-SIZEOF_POINTER	; void * gotptr

	align	16
	global	EXTN(jpeg_h2v2_merged_upsample_sse2)

EXTN(jpeg_h2v2_merged_upsample_sse2):
	push	ebp
	mov	eax,esp				; eax = original ebp
	sub	esp, byte 4
	and	esp, byte (-SIZEOF_XMMWORD)	; align to 128 bits
	mov	[esp],eax
	mov	ebp,esp				; ebp = aligned ebp
	lea	esp, [inptr2]
	pushpic	eax		; make a room for GOT address
	push	ebx
;	push	ecx		; need not be preserved
;	push	edx		; need not be preserved
	push	esi
	push	edi

	get_GOT	ebx			; get GOT address
	movpic	POINTER [gotptr], ebx	; save GOT address

	mov	ecx, POINTER [cinfo(eax)]
	mov	ecx, JDIMENSION [jdstruct_output_width(ecx)]	; col
	test	ecx,ecx
	jz	near .return

	push	ecx

	mov	edi, JSAMPIMAGE [input_buf(eax)]
	mov	ecx, JDIMENSION [in_row_group_ctr(eax)]
	mov	esi, JSAMPARRAY [edi+0*SIZEOF_JSAMPARRAY]
	mov	ebx, JSAMPARRAY [edi+1*SIZEOF_JSAMPARRAY]
	mov	edx, JSAMPARRAY [edi+2*SIZEOF_JSAMPARRAY]
	mov	edi, JSAMPARRAY [output_buf(eax)]
	mov	eax, JSAMPROW [esi+(ecx*2+0)*SIZEOF_JSAMPROW]	; inptr00
	mov	esi, JSAMPROW [esi+(ecx*2+1)*SIZEOF_JSAMPROW]	; inptr01
	mov	ebx, JSAMPROW [ebx+ecx*SIZEOF_JSAMPROW]		; inptr1
	mov	edx, JSAMPROW [edx+ecx*SIZEOF_JSAMPROW]		; inptr2

	pop	ecx		; col
	push	eax		; inptr00
	push	esi		; inptr01

	mov	esi, JSAMPROW [edi+0*SIZEOF_JSAMPROW]		; outptr0
	mov	edi, JSAMPROW [edi+1*SIZEOF_JSAMPROW]		; outptr1
	alignx	16,7
.columnloop:
	movpic	eax, POINTER [gotptr]	; load GOT address (eax)

	movdqa	xmm6, XMMWORD [ebx]	; xmm6=Cb(0123456789ABCDEF)
	movdqa	xmm7, XMMWORD [edx]	; xmm7=Cr(0123456789ABCDEF)

	mov	JSAMPROW [inptr1], ebx	; inptr1
	mov	JSAMPROW [inptr2], edx	; inptr2
	pop	edx			; edx=inptr01
	pop	ebx			; ebx=inptr00

	pxor      xmm1,xmm1		; xmm1=(all 0's)
	pcmpeqw   xmm3,xmm3
	psllw     xmm3,7		; xmm3={0xFF80 0xFF80 0xFF80 0xFF80 ..}

	movdqa    xmm4,xmm6
	punpckhbw xmm6,xmm1		; xmm6=Cb(89ABCDEF)=CbH
	punpcklbw xmm4,xmm1		; xmm4=Cb(01234567)=CbL
	movdqa    xmm0,xmm7
	punpckhbw xmm7,xmm1		; xmm7=Cr(89ABCDEF)=CrH
	punpcklbw xmm0,xmm1		; xmm0=Cr(01234567)=CrL

	paddw     xmm6,xmm3
	paddw     xmm4,xmm3
	paddw     xmm7,xmm3
	paddw     xmm0,xmm3

	; (Original)
	; R = Y                + 1.40200 * Cr
	; G = Y - 0.34414 * Cb - 0.71414 * Cr
	; B = Y + 1.77200 * Cb
	;
	; (This implementation)
	; R = Y                + 0.40200 * Cr + Cr
	; G = Y - 0.34414 * Cb + 0.28586 * Cr - Cr
	; B = Y - 0.22800 * Cb + Cb + Cb

	movdqa	xmm5,xmm6		; xmm5=CbH
	movdqa	xmm2,xmm4		; xmm2=CbL
	paddw	xmm6,xmm6		; xmm6=2*CbH
	paddw	xmm4,xmm4		; xmm4=2*CbL
	movdqa	xmm1,xmm7		; xmm1=CrH
	movdqa	xmm3,xmm0		; xmm3=CrL
	paddw	xmm7,xmm7		; xmm7=2*CrH
	paddw	xmm0,xmm0		; xmm0=2*CrL

	pmulhw	xmm6,[GOTOFF(eax,PW_MF0228)]	; xmm6=(2*CbH * -FIX(0.22800))
	pmulhw	xmm4,[GOTOFF(eax,PW_MF0228)]	; xmm4=(2*CbL * -FIX(0.22800))
	pmulhw	xmm7,[GOTOFF(eax,PW_F0402)]	; xmm7=(2*CrH * FIX(0.40200))
	pmulhw	xmm0,[GOTOFF(eax,PW_F0402)]	; xmm0=(2*CrL * FIX(0.40200))

	paddw	xmm6,[GOTOFF(eax,PW_ONE)]
	paddw	xmm4,[GOTOFF(eax,PW_ONE)]
	psraw	xmm6,1			; xmm6=(CbH * -FIX(0.22800))
	psraw	xmm4,1			; xmm4=(CbL * -FIX(0.22800))
	paddw	xmm7,[GOTOFF(eax,PW_ONE)]
	paddw	xmm0,[GOTOFF(eax,PW_ONE)]
	psraw	xmm7,1			; xmm7=(CrH * FIX(0.40200))
	psraw	xmm0,1			; xmm0=(CrL * FIX(0.40200))

	paddw	xmm6,xmm5
	paddw	xmm4,xmm2
	paddw	xmm6,xmm5		; xmm6=(CbH * FIX(1.77200))=(B-Y)H
	paddw	xmm4,xmm2		; xmm4=(CbL * FIX(1.77200))=(B-Y)L
	paddw	xmm7,xmm1		; xmm7=(CrH * FIX(1.40200))=(R-Y)H
	paddw	xmm0,xmm3		; xmm0=(CrL * FIX(1.40200))=(R-Y)L

	movdqa	XMMWORD [wk(0)], xmm6	; wk(0)=(B-Y)H
	movdqa	XMMWORD [wk(1)], xmm7	; wk(1)=(R-Y)H

	movdqa    xmm6,xmm5
	movdqa    xmm7,xmm2
	punpcklwd xmm5,xmm1
	punpckhwd xmm6,xmm1
	pmaddwd   xmm5,[GOTOFF(eax,PW_MF0344_F0285)]
	pmaddwd   xmm6,[GOTOFF(eax,PW_MF0344_F0285)]
	punpcklwd xmm2,xmm3
	punpckhwd xmm7,xmm3
	pmaddwd   xmm2,[GOTOFF(eax,PW_MF0344_F0285)]
	pmaddwd   xmm7,[GOTOFF(eax,PW_MF0344_F0285)]

	paddd     xmm5,[GOTOFF(eax,PD_ONEHALF)]
	paddd     xmm6,[GOTOFF(eax,PD_ONEHALF)]
	psrad     xmm5,SCALEBITS
	psrad     xmm6,SCALEBITS
	paddd     xmm2,[GOTOFF(eax,PD_ONEHALF)]
	paddd     xmm7,[GOTOFF(eax,PD_ONEHALF)]
	psrad     xmm2,SCALEBITS
	psrad     xmm7,SCALEBITS

	packssdw  xmm5,xmm6	; xmm5=CbH*-FIX(0.344)+CrH*FIX(0.285)
	packssdw  xmm2,xmm7	; xmm2=CbL*-FIX(0.344)+CrL*FIX(0.285)
	psubw     xmm5,xmm1	; xmm5=CbH*-FIX(0.344)+CrH*-FIX(0.714)=(G-Y)H
	psubw     xmm2,xmm3	; xmm2=CbL*-FIX(0.344)+CrL*-FIX(0.714)=(G-Y)L

	movdqa	XMMWORD [wk(2)], xmm5	; wk(2)=(G-Y)H

	mov	ah,2			; YHctr
	jmp	short .YHloop_1st
	alignx	16,7

.YHloop_2nd:
	movdqa	xmm0, XMMWORD [wk(1)]	; xmm0=(R-Y)H
	movdqa	xmm2, XMMWORD [wk(2)]	; xmm2=(G-Y)H
	movdqa	xmm4, XMMWORD [wk(0)]	; xmm4=(B-Y)H
	alignx	16,7

.YHloop_1st:
	movdqa	XMMWORD [wk(3)], xmm0	; wk(3)=(R-Y)(L/H)
	movdqa	XMMWORD [wk(4)], xmm2	; wk(4)=(G-Y)(L/H)
	movdqa	XMMWORD [wk(5)], xmm4	; wk(5)=(B-Y)(L/H)

	movdqa	xmm7, XMMWORD [ebx]	; xmm7=Y(0123456789ABCDEF)

	mov	al,2			; YVctr
	jmp	short .YVloop_1st
	alignx	16,7

.YVloop_2nd:
	movdqa	xmm0, XMMWORD [wk(3)]	; xmm0=(R-Y)(L/H)
	movdqa	xmm2, XMMWORD [wk(4)]	; xmm2=(G-Y)(L/H)
	movdqa	xmm4, XMMWORD [wk(5)]	; xmm4=(B-Y)(L/H)

	movdqa	xmm7, XMMWORD [edx]	; xmm7=Y(0123456789ABCDEF)
	alignx	16,7

.YVloop_1st:
	pcmpeqw	xmm6,xmm6
	psrlw	xmm6,BYTE_BIT		; xmm6={0xFF 0x00 0xFF 0x00 ..}
	pand	xmm6,xmm7		; xmm6=Y(02468ACE)=YE
	psrlw	xmm7,BYTE_BIT		; xmm7=Y(13579BDF)=YO

	movdqa	xmm1,xmm0		; xmm1=xmm0=(R-Y)(L/H)
	movdqa	xmm3,xmm2		; xmm3=xmm2=(G-Y)(L/H)
	movdqa	xmm5,xmm4		; xmm5=xmm4=(B-Y)(L/H)

	paddw     xmm0,xmm6		; xmm0=((R-Y)+YE)=RE=R(02468ACE)
	paddw     xmm1,xmm7		; xmm1=((R-Y)+YO)=RO=R(13579BDF)
	packuswb  xmm0,xmm0		; xmm0=R(02468ACE********)
	packuswb  xmm1,xmm1		; xmm1=R(13579BDF********)

	paddw     xmm2,xmm6		; xmm2=((G-Y)+YE)=GE=G(02468ACE)
	paddw     xmm3,xmm7		; xmm3=((G-Y)+YO)=GO=G(13579BDF)
	packuswb  xmm2,xmm2		; xmm2=G(02468ACE********)
	packuswb  xmm3,xmm3		; xmm3=G(13579BDF********)

	paddw     xmm4,xmm6		; xmm4=((B-Y)+YE)=BE=B(02468ACE)
	paddw     xmm5,xmm7		; xmm5=((B-Y)+YO)=BO=B(13579BDF)
	packuswb  xmm4,xmm4		; xmm4=B(02468ACE********)
	packuswb  xmm5,xmm5		; xmm5=B(13579BDF********)

%if RGB_PIXELSIZE == 3 ; ---------------

	; xmmA=(00 02 04 06 08 0A 0C 0E **), xmmB=(01 03 05 07 09 0B 0D 0F **)
	; xmmC=(10 12 14 16 18 1A 1C 1E **), xmmD=(11 13 15 17 19 1B 1D 1F **)
	; xmmE=(20 22 24 26 28 2A 2C 2E **), xmmF=(21 23 25 27 29 2B 2D 2F **)
	; xmmG=(** ** ** ** ** ** ** ** **), xmmH=(** ** ** ** ** ** ** ** **)

	punpcklbw xmmA,xmmC	; xmmA=(00 10 02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E)
	punpcklbw xmmE,xmmB	; xmmE=(20 01 22 03 24 05 26 07 28 09 2A 0B 2C 0D 2E 0F)
	punpcklbw xmmD,xmmF	; xmmD=(11 21 13 23 15 25 17 27 19 29 1B 2B 1D 2D 1F 2F)

	movdqa    xmmG,xmmA
	movdqa    xmmH,xmmA
	punpcklwd xmmA,xmmE	; xmmA=(00 10 20 01 02 12 22 03 04 14 24 05 06 16 26 07)
	punpckhwd xmmG,xmmE	; xmmG=(08 18 28 09 0A 1A 2A 0B 0C 1C 2C 0D 0E 1E 2E 0F)

	psrldq    xmmH,2	; xmmH=(02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E -- --)
	psrldq    xmmE,2	; xmmE=(22 03 24 05 26 07 28 09 2A 0B 2C 0D 2E 0F -- --)

	movdqa    xmmC,xmmD
	movdqa    xmmB,xmmD
	punpcklwd xmmD,xmmH	; xmmD=(11 21 02 12 13 23 04 14 15 25 06 16 17 27 08 18)
	punpckhwd xmmC,xmmH	; xmmC=(19 29 0A 1A 1B 2B 0C 1C 1D 2D 0E 1E 1F 2F -- --)

	psrldq    xmmB,2	; xmmB=(13 23 15 25 17 27 19 29 1B 2B 1D 2D 1F 2F -- --)

	movdqa    xmmF,xmmE
	punpcklwd xmmE,xmmB	; xmmE=(22 03 13 23 24 05 15 25 26 07 17 27 28 09 19 29)
	punpckhwd xmmF,xmmB	; xmmF=(2A 0B 1B 2B 2C 0D 1D 2D 2E 0F 1F 2F -- -- -- --)

	pshufd    xmmH,xmmA,0x4E; xmmH=(04 14 24 05 06 16 26 07 00 10 20 01 02 12 22 03)
	movdqa    xmmB,xmmE
	punpckldq xmmA,xmmD	; xmmA=(00 10 20 01 11 21 02 12 02 12 22 03 13 23 04 14)
	punpckldq xmmE,xmmH	; xmmE=(22 03 13 23 04 14 24 05 24 05 15 25 06 16 26 07)
	punpckhdq xmmD,xmmB	; xmmD=(15 25 06 16 26 07 17 27 17 27 08 18 28 09 19 29)

	pshufd    xmmH,xmmG,0x4E; xmmH=(0C 1C 2C 0D 0E 1E 2E 0F 08 18 28 09 0A 1A 2A 0B)
	movdqa    xmmB,xmmF
	punpckldq xmmG,xmmC	; xmmG=(08 18 28 09 19 29 0A 1A 0A 1A 2A 0B 1B 2B 0C 1C)
	punpckldq xmmF,xmmH	; xmmF=(2A 0B 1B 2B 0C 1C 2C 0D 2C 0D 1D 2D 0E 1E 2E 0F)
	punpckhdq xmmC,xmmB	; xmmC=(1D 2D 0E 1E 2E 0F 1F 2F 1F 2F -- -- -- -- -- --)

	punpcklqdq xmmA,xmmE	; xmmA=(00 10 20 01 11 21 02 12 22 03 13 23 04 14 24 05)
	punpcklqdq xmmD,xmmG	; xmmD=(15 25 06 16 26 07 17 27 08 18 28 09 19 29 0A 1A)
	punpcklqdq xmmF,xmmC	; xmmF=(2A 0B 1B 2B 0C 1C 2C 0D 1D 2D 0E 1E 2E 0F 1F 2F)

	dec	al			; YVctr
	jz	short .YVloop_break

	movdqa	XMMWORD [wk(6)], xmmA
	movdqa	XMMWORD [wk(7)], xmmD
	movdqa	XMMWORD [wk(8)], xmmF

	jmp	near .YVloop_2nd
	alignx	16,7

.YVloop_break:
	movdqa	xmmH, XMMWORD [wk(6)]
	movdqa	xmmB, XMMWORD [wk(7)]
	movdqa	xmmE, XMMWORD [wk(8)]

	pcmpeqb	xmmG,xmmG	; xmmG=(all 1's)

	cmp	ecx, byte SIZEOF_XMMWORD
	jb	near .column_st32

	test	edi, SIZEOF_XMMWORD-1
	jnz	short .out01
	; --(aligned)-------------------
	movntdq	XMMWORD [edi+0*SIZEOF_XMMWORD], xmmA
	movntdq	XMMWORD [edi+1*SIZEOF_XMMWORD], xmmD
	movntdq	XMMWORD [edi+2*SIZEOF_XMMWORD], xmmF
	add	edi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr1
	jmp	short .out00
.out01:	; --(unaligned)-----------------
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmD,xmmG			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmF,xmmG			; movntdqu XMMWORD [edi], xmmF
	add	edi, byte SIZEOF_XMMWORD	; outptr1
.out00:
	test	esi, SIZEOF_XMMWORD-1
	jnz	short .out11
	; --(aligned)-------------------
	movntdq	XMMWORD [esi+0*SIZEOF_XMMWORD], xmmH
	movntdq	XMMWORD [esi+1*SIZEOF_XMMWORD], xmmB
	movntdq	XMMWORD [esi+2*SIZEOF_XMMWORD], xmmE
	add	esi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr0
	jmp	short .out10
.out11:	; --(unaligned)-----------------
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmH,xmmG			; movntdqu XMMWORD [edi], xmmH
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmB,xmmG			; movntdqu XMMWORD [edi], xmmB
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmE,xmmG			; movntdqu XMMWORD [edi], xmmE
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
.out10:
	sub	ecx, byte SIZEOF_XMMWORD
	jz	near .endcolumn

	add	ebx, byte SIZEOF_XMMWORD	; inptr00
	add	edx, byte SIZEOF_XMMWORD	; inptr01
	dec	ah			; YHctr
	jnz	near .YHloop_2nd

	push	ebx				; inptr00
	push	edx				; inptr01
	mov	ebx, JSAMPROW [inptr1]		; ebx=inptr1
	mov	edx, JSAMPROW [inptr2]		; edx=inptr2
	add	ebx, byte SIZEOF_XMMWORD	; inptr1
	add	edx, byte SIZEOF_XMMWORD	; inptr2
	jmp	near .columnloop
	alignx	16,7

.column_st32:
	lea	ecx, [ecx+ecx*2]		; imul ecx, RGB_PIXELSIZE
	cmp	ecx, byte 2*SIZEOF_XMMWORD
	jb	short .column_st16
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmD,xmmG			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmH,xmmG			; movntdqu XMMWORD [edi], xmmH
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmB,xmmG			; movntdqu XMMWORD [edi], xmmB
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
	movdqa	xmmA,xmmF
	movdqa	xmmH,xmmE
	sub	ecx, byte 2*SIZEOF_XMMWORD
	jmp	short .column_st15
.column_st16:
	cmp	ecx, byte SIZEOF_XMMWORD
	jb	short .column_st15
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmH,xmmG			; movntdqu XMMWORD [edi], xmmH
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
	movdqa	xmmA,xmmD
	movdqa	xmmH,xmmB
	sub	ecx, byte SIZEOF_XMMWORD
.column_st15:
	mov	edx,ecx
	xor	ecx, byte 0x0F
	shl	ecx, 2
	movd	xmmC,ecx
	psrlq	xmmG,4
	pcmpeqb	xmmD,xmmD
	psrlq	xmmG,xmmC
	psrlq	xmmD,xmmC
	punpcklbw xmmD,xmmG
	movdqa    xmmB,xmmD
	; ================
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0a
	lea	eax, [ecx+edx]
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0a
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmA,ecx & pslldq xmmD,ecx
	movdqa	xmmF,xmmA
	movdqa	xmmE,xmmD
	pslldq	xmmA, SIZEOF_XMMWORD/2
	pslldq	xmmD, SIZEOF_XMMWORD/2
	movd	xmmC,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1a
	movd	xmmG,ecx
	psllq	xmmA,xmmG
	psllq	xmmD,xmmG
	jmp	short .adj0a
.adj1a:	neg	ecx
	movd	xmmG,ecx
	psrlq	xmmA,xmmG
	psrlq	xmmD,xmmG
	psllq	xmmF,xmmC
	psllq	xmmE,xmmC
	por	xmmA,xmmF
	por	xmmD,xmmE
.adj0a:	; ----------------
	maskmovdqu xmmA,xmmD			; movntdqu XMMWORD [edi], xmmA
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	; ================
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0b
	lea	eax, [ecx+edx]
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0b
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmH,ecx & pslldq xmmB,ecx
	movdqa	xmmG,xmmH
	movdqa	xmmC,xmmB
	pslldq	xmmH, SIZEOF_XMMWORD/2
	pslldq	xmmB, SIZEOF_XMMWORD/2
	movd	xmmF,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1b
	movd	xmmE,ecx
	psllq	xmmH,xmmE
	psllq	xmmB,xmmE
	jmp	short .adj0b
.adj1b:	neg	ecx
	movd	xmmE,ecx
	psrlq	xmmH,xmmE
	psrlq	xmmB,xmmE
	psllq	xmmG,xmmF
	psllq	xmmC,xmmF
	por	xmmH,xmmG
	por	xmmB,xmmC
.adj0b:	; ----------------
	maskmovdqu xmmH,xmmB			; movntdqu XMMWORD [edi], xmmH

%else ; RGB_PIXELSIZE == 4 ; -----------

%ifdef RGBX_FILLER_0XFF
	pcmpeqb   xmm6,xmm6		; xmm6=XE=X(02468ACE********)
	pcmpeqb   xmm7,xmm7		; xmm7=XO=X(13579BDF********)
%else
	pxor      xmm6,xmm6		; xmm6=XE=X(02468ACE********)
	pxor      xmm7,xmm7		; xmm7=XO=X(13579BDF********)
%endif
	; xmmA=(00 02 04 06 08 0A 0C 0E **), xmmB=(01 03 05 07 09 0B 0D 0F **)
	; xmmC=(10 12 14 16 18 1A 1C 1E **), xmmD=(11 13 15 17 19 1B 1D 1F **)
	; xmmE=(20 22 24 26 28 2A 2C 2E **), xmmF=(21 23 25 27 29 2B 2D 2F **)
	; xmmG=(30 32 34 36 38 3A 3C 3E **), xmmH=(31 33 35 37 39 3B 3D 3F **)

	punpcklbw xmmA,xmmC	; xmmA=(00 10 02 12 04 14 06 16 08 18 0A 1A 0C 1C 0E 1E)
	punpcklbw xmmE,xmmG	; xmmE=(20 30 22 32 24 34 26 36 28 38 2A 3A 2C 3C 2E 3E)
	punpcklbw xmmB,xmmD	; xmmB=(01 11 03 13 05 15 07 17 09 19 0B 1B 0D 1D 0F 1F)
	punpcklbw xmmF,xmmH	; xmmF=(21 31 23 33 25 35 27 37 29 39 2B 3B 2D 3D 2F 3F)

	movdqa    xmmC,xmmA
	punpcklwd xmmA,xmmE	; xmmA=(00 10 20 30 02 12 22 32 04 14 24 34 06 16 26 36)
	punpckhwd xmmC,xmmE	; xmmC=(08 18 28 38 0A 1A 2A 3A 0C 1C 2C 3C 0E 1E 2E 3E)
	movdqa    xmmG,xmmB
	punpcklwd xmmB,xmmF	; xmmB=(01 11 21 31 03 13 23 33 05 15 25 35 07 17 27 37)
	punpckhwd xmmG,xmmF	; xmmG=(09 19 29 39 0B 1B 2B 3B 0D 1D 2D 3D 0F 1F 2F 3F)

	movdqa    xmmD,xmmA
	punpckldq xmmA,xmmB	; xmmA=(00 10 20 30 01 11 21 31 02 12 22 32 03 13 23 33)
	punpckhdq xmmD,xmmB	; xmmD=(04 14 24 34 05 15 25 35 06 16 26 36 07 17 27 37)
	movdqa    xmmH,xmmC
	punpckldq xmmC,xmmG	; xmmC=(08 18 28 38 09 19 29 39 0A 1A 2A 3A 0B 1B 2B 3B)
	punpckhdq xmmH,xmmG	; xmmH=(0C 1C 2C 3C 0D 1D 2D 3D 0E 1E 2E 3E 0F 1F 2F 3F)

	dec	al			; YVctr
	jz	short .YVloop_break

	movdqa	XMMWORD [wk(6)], xmmA
	movdqa	XMMWORD [wk(7)], xmmD
	movdqa	XMMWORD [wk(8)], xmmC
	movdqa	XMMWORD [wk(9)], xmmH

	jmp	near .YVloop_2nd
	alignx	16,7

.YVloop_break:
	movdqa	xmmE, XMMWORD [wk(6)]
	movdqa	xmmF, XMMWORD [wk(7)]
	movdqa	xmmB, XMMWORD [wk(8)]

	pcmpeqb	xmmG,xmmG	; xmmG=(all 1's)

	cmp	ecx, byte SIZEOF_XMMWORD
	jb	near .column_st32

	test	edi, SIZEOF_XMMWORD-1
	jnz	short .out01
	; --(aligned)-------------------
	movntdq	XMMWORD [edi+0*SIZEOF_XMMWORD], xmmA
	movntdq	XMMWORD [edi+1*SIZEOF_XMMWORD], xmmD
	movntdq	XMMWORD [edi+2*SIZEOF_XMMWORD], xmmC
	movntdq	XMMWORD [edi+3*SIZEOF_XMMWORD], xmmH
	add	edi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr1
	jmp	short .out00
.out01:	; --(unaligned)-----------------
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmD,xmmG			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmC,xmmG			; movntdqu XMMWORD [edi], xmmC
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmH,xmmG			; movntdqu XMMWORD [edi], xmmH
	add	edi, byte SIZEOF_XMMWORD	; outptr1
.out00:
	movdqa	xmmA, XMMWORD [wk(9)]

	test	esi, SIZEOF_XMMWORD-1
	jnz	short .out11
	; --(aligned)-------------------
	movntdq	XMMWORD [esi+0*SIZEOF_XMMWORD], xmmE
	movntdq	XMMWORD [esi+1*SIZEOF_XMMWORD], xmmF
	movntdq	XMMWORD [esi+2*SIZEOF_XMMWORD], xmmB
	movntdq	XMMWORD [esi+3*SIZEOF_XMMWORD], xmmA
	add	esi, byte RGB_PIXELSIZE*SIZEOF_XMMWORD	; outptr0
	jmp	short .out10
.out11:	; --(unaligned)-----------------
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmE,xmmG			; movntdqu XMMWORD [edi], xmmE
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmF,xmmG			; movntdqu XMMWORD [edi], xmmF
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmB,xmmG			; movntdqu XMMWORD [edi], xmmB
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
.out10:
	sub	ecx, byte SIZEOF_XMMWORD
	jz	near .endcolumn

	add	ebx, byte SIZEOF_XMMWORD	; inptr00
	add	edx, byte SIZEOF_XMMWORD	; inptr01
	dec	ah			; YHctr
	jnz	near .YHloop_2nd

	push	ebx				; inptr00
	push	edx				; inptr01
	mov	ebx, JSAMPROW [inptr1]		; ebx=inptr1
	mov	edx, JSAMPROW [inptr2]		; edx=inptr2
	add	ebx, byte SIZEOF_XMMWORD	; inptr1
	add	edx, byte SIZEOF_XMMWORD	; inptr2
	jmp	near .columnloop
	alignx	16,7

.column_st32:
	cmp	ecx, byte SIZEOF_XMMWORD/2
	jb	short .column_st16
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	maskmovdqu xmmD,xmmG			; movntdqu XMMWORD [edi], xmmD
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmE,xmmG			; movntdqu XMMWORD [edi], xmmE
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	maskmovdqu xmmF,xmmG			; movntdqu XMMWORD [edi], xmmF
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
	movdqa	xmmA,xmmC
	movdqa	xmmD,xmmH
	movdqa	xmmE,xmmB
	movdqa	xmmF, XMMWORD [wk(9)]
	sub	ecx, byte SIZEOF_XMMWORD/2
.column_st16:
	cmp	ecx, byte SIZEOF_XMMWORD/4
	jb	short .column_st15
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	add	edi, byte SIZEOF_XMMWORD	; outptr1
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	maskmovdqu xmmE,xmmG			; movntdqu XMMWORD [edi], xmmE
	add	edi, byte SIZEOF_XMMWORD	; outptr0
	xchg	edi,esi				; edi=outptr1, esi=outptr0
	movdqa	xmmA,xmmD
	movdqa	xmmE,xmmF
	sub	ecx, byte SIZEOF_XMMWORD/4
.column_st15:
	cmp	ecx, byte SIZEOF_XMMWORD/16
	jb	near .endcolumn
	mov	edx,ecx
	xor	ecx, byte 0x03
	inc	ecx
	shl	ecx, 4
	movd	xmmC,ecx
	psrlq	xmmG,xmmC
	punpcklbw xmmG,xmmG
	movdqa    xmmH,xmmG
	; ================
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0a
	lea	eax, [ecx+edx*4]	; RGB_PIXELSIZE
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0a
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmA,ecx & pslldq xmmG,ecx
	movdqa	xmmB,xmmA
	movdqa	xmmD,xmmG
	pslldq	xmmA, SIZEOF_XMMWORD/2
	pslldq	xmmG, SIZEOF_XMMWORD/2
	movd	xmmF,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1a
	movd	xmmC,ecx
	psllq	xmmA,xmmC
	psllq	xmmG,xmmC
	jmp	short .adj0a
.adj1a:	neg	ecx
	movd	xmmC,ecx
	psrlq	xmmA,xmmC
	psrlq	xmmG,xmmC
	psllq	xmmB,xmmF
	psllq	xmmD,xmmF
	por	xmmA,xmmB
	por	xmmG,xmmD
.adj0a:	; ----------------
	maskmovdqu xmmA,xmmG			; movntdqu XMMWORD [edi], xmmA
	xchg	edi,esi				; edi=outptr0, esi=outptr1
	; ================
	mov	ecx,edi
	and	ecx, byte SIZEOF_XMMWORD-1
	jz	short .adj0b
	lea	eax, [ecx+edx*4]	; RGB_PIXELSIZE
	cmp	eax, byte SIZEOF_XMMWORD
	ja	short .adj0b
	and	edi, byte (-SIZEOF_XMMWORD)	; align to 16-byte boundary
	shl	ecx, 3			; pslldq xmmE,ecx & pslldq xmmH,ecx
	movdqa	xmmC,xmmE
	movdqa	xmmF,xmmH
	pslldq	xmmE, SIZEOF_XMMWORD/2
	pslldq	xmmH, SIZEOF_XMMWORD/2
	movd	xmmB,ecx
	sub	ecx, byte (SIZEOF_XMMWORD/2)*BYTE_BIT
	jb	short .adj1b
	movd	xmmD,ecx
	psllq	xmmE,xmmD
	psllq	xmmH,xmmD
	jmp	short .adj0b
.adj1b:	neg	ecx
	movd	xmmD,ecx
	psrlq	xmmE,xmmD
	psrlq	xmmH,xmmD
	psllq	xmmC,xmmB
	psllq	xmmF,xmmB
	por	xmmE,xmmC
	por	xmmH,xmmF
.adj0b:	; ----------------
	maskmovdqu xmmE,xmmH			; movntdqu XMMWORD [edi], xmmE

%endif ; RGB_PIXELSIZE ; ---------------

.endcolumn:
	sfence		; flush the write buffer

.return:
	pop	edi
	pop	esi
;	pop	edx		; need not be preserved
;	pop	ecx		; need not be preserved
	pop	ebx
	mov	esp,ebp		; esp <- aligned ebp
	pop	esp		; esp <- original ebp
	pop	ebp
	ret

%endif ; !USE_DEDICATED_H2V2_MERGED_UPSAMPLE_SSE2

%endif ; JDMERGE_SSE2_SUPPORTED
%endif ; UPSAMPLE_MERGING_SUPPORTED
%endif ; RGB_PIXELSIZE == 3 || RGB_PIXELSIZE == 4
