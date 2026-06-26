    PROCESSOR   18F47Q84
    #include    <xc.inc>

    EXTERN seconds, minutes, hours, day, month, yearL, yearH
    EXTERN uptime_minutesL, uptime_minutesH
    EXTERN slide_timer, current_info_slide, current_off_slide
    EXTERN sleep_timeout_counter, pump_state, manual_chrono_secL, manual_chrono_secH
    
    GLOBAL High_ISR

; ============================================================================
; GESTION DES INTERRUPTIONS (TIMER0 @ 1 SEC)
; ============================================================================
    PSECT intcode, class=CODE, reloc=2
High_ISR:
    ; Context saving is automatic on PIC18FxxQ84
    
    ; Check TMR0IF (PIR0 bit 5)
    BTFSS PIR0, 5 
    BRA End_ISR

    ; Increment seconds & slide_timer
    INCF seconds, F
    INCF slide_timer, F

    ; Sleep timeout logic (SW_SYSTEM_OFF == 1)
    BTFSS PORTB, 0      ; RB0 is active low, 1 means OFF
    BRA ISR_PumpChrono
    
    MOVLW 4             ; SLEEP_DELAY
    CPFSGT sleep_timeout_counter
    INCF sleep_timeout_counter, F

ISR_PumpChrono:
    ; Manual chrono if pump_state=1, SW_MANUAL_PUMP(RB1)=0, SW_SYSTEM_OFF(RB0)=0
    BTFSS pump_state, 0
    BRA ISR_Calendar
    BTFSC PORTB, 1
    BRA ISR_Calendar
    BTFSC PORTB, 0
    BRA ISR_Calendar
    
    INCF manual_chrono_secL, F
    BTFSC STATUS, 0     ; Check carry
    INCF manual_chrono_secH, F

ISR_Calendar:
    MOVLW 60
    CPFSLT seconds
    BRA Reset_Seconds
    BRA ISR_Slides

Reset_Seconds:
    CLRF seconds
    INCF minutes, F
    
    ; Uptime minutes increment
    INCF uptime_minutesL, F
    BTFSC STATUS, 0
    INCF uptime_minutesH, F

    MOVLW 60
    CPFSLT minutes
    BRA Reset_Minutes
    BRA ISR_Slides

Reset_Minutes:
    CLRF minutes
    INCF hours, F

    MOVLW 24
    CPFSLT hours
    BRA Reset_Hours
    BRA ISR_Slides

Reset_Hours:
    CLRF hours
    INCF day, F

ISR_Slides:
    MOVLW 4 ; SLIDE_DURATION
    CPFSLT slide_timer
    BRA Reset_Slides
    BRA Reload_Timer

Reset_Slides:
    CLRF slide_timer
    
    INCF current_info_slide, W
    ANDLW 0x03 ; Modulo 4 (0 to 3)
    MOVWF current_info_slide
    
    INCF current_off_slide, W
    ANDLW 0x01 ; Modulo 2 (0 to 1)
    MOVWF current_off_slide

Reload_Timer:
    MOVLW 0x0B
    MOVWF TMR0H
    MOVLW 0xDC
    MOVWF TMR0L
    BCF PIR0, 5 ; Clear TMR0IF flag

End_ISR:
    RETFIE  1

    END
