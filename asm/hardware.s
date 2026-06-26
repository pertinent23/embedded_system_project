    PROCESSOR   18F47Q84
    #include    <xc.inc>

    EXTERN delay_cnt1, delay_cnt2
    GLOBAL System_Initialize, Timer0_Initialize, ADC_Read_Moisture
    GLOBAL Delay_ms, Delay_us

    PSECT text, class=CODE, reloc=2

; ============================================================================
; INITIALISATION SYSTÈME
; ============================================================================
System_Initialize:
    ; Config Port A (RA2 = Analog Input, RA1 = Power Pin Output)
    MOVLW 00000100B
    MOVWF TRISA
    MOVWF ANSELA
    CLRF LATA

    ; Reset ADC registers
    CLRF ADCON0
    CLRF ADCON1
    CLRF ADCON2
    CLRF ADCON3

    ; Enable ADC, Use internal RC oscillator, Right Justified
    BSF ADCON0, 7 ; ON
    BSF ADCON0, 4 ; CS
    BSF ADCON0, 2 ; FM

    CLRF ADREF
    MOVLW 0x02    ; Channel ANA2 (RA2)
    MOVWF ADPCH
    MOVLW 0x20    ; Acquisition time
    MOVWF ADACQ

    ; Config Port D (RD0=Relay, RD1=LED Green, RD2=LED Red)
    CLRF TRISD
    CLRF ANSELD
    MOVLW 0x01    ; RD0 high (Relay off)
    MOVWF LATD

    ; Config Port B (RB0, RB1, RB2 as Inputs with Pull-ups)
    MOVLW 00000111B
    MOVWF TRISB
    CLRF ANSELB
    MOVLW 00000111B
    MOVWF WPUB    ; Weak pull-ups enabled
    
    RETURN

; ============================================================================
; INITIALISATION TIMER0
; ============================================================================
Timer0_Initialize:
    MOVLW 0x90    ; T0EN=1, 16-bit
    MOVWF T0CON0
    MOVLW 0x48    ; Fosc/4, 1:256 prescaler
    MOVWF T0CON1

    MOVLW 0x0B
    MOVWF TMR0H
    MOVLW 0xDC
    MOVWF TMR0L

    BSF PIE0, 5   ; Enable Timer0 interrupt
    RETURN

; ============================================================================
; ROUTINES DE DÉLAI BLOQUANT (FOSC=64MHZ -> 1 CYCLE = 62.5NS)
; ============================================================================
Delay_ms:
    ; WREG contains ms to delay.
    MOVWF delay_cnt2
Delay_ms_loop:
    MOVLW 250
    CALL Delay_us
    MOVLW 250
    CALL Delay_us
    MOVLW 250
    CALL Delay_us
    MOVLW 250
    CALL Delay_us
    DECFSZ delay_cnt2, F
    BRA Delay_ms_loop
    RETURN

Delay_us:
    ; WREG contains us to delay. 1us = 16 instructions
    MOVWF delay_cnt1
Delay_us_loop:
    ; Loop takes 3 cycles -> 16/3 ~ 5 loops per us
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    DECFSZ delay_cnt1, F
    BRA Delay_us_loop
    RETURN

; ============================================================================
; LECTURE ADC (100 ÉCHANTILLONS MOYENNÉS)
; ============================================================================
ADC_Read_Moisture:
    ; This function returns the averaged 16-bit value in math_resL and math_resH
    ; Using math_arg1/2 for summing.
    BSF LATA, 1       ; HYGRO_POWER_PIN = 1
    MOVLW 50
    CALL Delay_ms     ; Wait 50ms
    
    ; Init sum
    CLRF math_arg1L
    CLRF math_arg1H
    CLRF math_arg2L   ; Use as 3rd byte of sum (24-bit sum)

    ; Loop 100 times
    MOVLW 100
    MOVWF delay_cnt2

ADC_Loop:
    BSF ADCON0, 0     ; GO = 1
ADC_Wait:
    BTFSC ADCON0, 0
    BRA ADC_Wait

    ; Add to 24-bit sum
    MOVF ADRESL, W
    ADDWF math_arg1L, F
    MOVF ADRESH, W
    ADDWFC math_arg1H, F
    MOVLW 0
    ADDWFC math_arg2L, F

    MOVLW 100
    CALL Delay_us

    DECFSZ delay_cnt2, F
    BRA ADC_Loop

    BCF LATA, 1       ; HYGRO_POWER_PIN = 0

    ; Divide 24-bit sum by 100 (Simplified approximation / Division par boucles)
    ; In reality we need a true division algorithm here.
    ; math_res = sum / 100
    
    CLRF math_resL
    CLRF math_resH
Div_Loop:
    ; sum = sum - 100
    MOVLW 100
    SUBWF math_arg1L, F
    MOVLW 0
    SUBWFB math_arg1H, F
    MOVLW 0
    SUBWFB math_arg2L, F
    
    ; If borrow (carry=0), we passed 0, we are done
    BTFSS STATUS, 0
    BRA Div_Done
    
    ; res++
    INCF math_resL, F
    BTFSC STATUS, 0
    INCF math_resH, F
    
    BRA Div_Loop

Div_Done:
    ; Result is now in math_resH:math_resL
    RETURN

    END
