    PROCESSOR   18F47Q84
    #include    <xc.inc>

    EXTERN System_Initialize, Timer0_Initialize, ADC_Read_Moisture
    EXTERN I2C_Init, LCD_Init, LCD_SetCursor, LCD_String, LCD_Char, Delay_ms
    
    ; Intégration Wi-Fi
    EXTERN WIFI_Init, WIFI_Task
    EXTERN wifi_sys_off, wifi_manual_pump, wifi_info_mode
    
    EXTERN seconds, minutes, hours, day, month, yearL, yearH
    EXTERN uptime_minutesL, uptime_minutesH, raw_moistureL, raw_moistureH
    EXTERN humidity_percent, pump_state, manual_chrono_secL, manual_chrono_secH
    EXTERN slide_timer, current_info_slide, current_off_slide, backlight_status
    EXTERN sleep_timeout_counter, lcd_line1, lcd_line2
    
    EXTERN math_resL, math_resH, math_arg1L, math_arg1H, math_arg2L, math_arg2H, math_remL, math_remH

    GLOBAL main, System_Control_Logic, Update_Display

PRINT_ROM MACRO string_label
    MOVLW low highword(string_label)
    MOVWF TBLPTRU
    MOVLW high(string_label)
    MOVWF TBLPTRH
    MOVLW low(string_label)
    MOVWF TBLPTRL
    CALL LCD_String_ROM
    ENDM

    PSECT text, class=CODE, reloc=2

main:
    CALL System_Initialize
    CALL I2C_Init
    CALL LCD_Init
    CALL WIFI_Init  ; <- Ajout initialisation Wi-Fi
    
    ; Init horloge
    MOVLW 12
    MOVWF hours
    MOVLW 1
    MOVWF day
    MOVWF month

    CALL Timer0_Initialize
    BSF INTCON0, 7 ; GIE = 1

    ; Splash Screen
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Firmaware

    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    PRINT_ROM Str_Init

    MOVLW 150
    CALL Delay_ms

MainLoop:
    ; --- INTÉGRATION WI-FI ---
    CALL WIFI_Task ; Machine à états non-bloquante exécutée à chaque tour de boucle

    ; ÉTAPE A : Acquisition Analogique
    CALL ADC_Read_Moisture
    MOVFF math_resL, raw_moistureL
    MOVFF math_resH, raw_moistureH

    ; ÉTAPE B : Calcul Mathématique Borne (Sécurité)
    MOVFF raw_moistureL, math_arg1L
    MOVFF raw_moistureH, math_arg1H
    
    ; Borne basse (750 = 0x02EE)
    MOVLW 0x02
    CPFSLT math_arg1H
    BRA Check_Borne_Low_L
    BRA Set_750
Check_Borne_Low_L:
    CPFSGT math_arg1H
    BRA Check_Borne_Low_L_Strict
    BRA Do_Math
Check_Borne_Low_L_Strict:
    MOVLW 0xEE
    CPFSLT math_arg1L
    BRA Do_Math
Set_750:
    MOVLW 0xEE
    MOVWF math_arg1L
    MOVLW 0x02
    MOVWF math_arg1H

Do_Math:
    ; humidity_percent = 100 - ((temp_adc - 750) / 33)
    MOVLW 0xEE
    SUBWF math_arg1L, F
    MOVLW 0x02
    SUBWFB math_arg1H, F
    
    CLRF math_resL
Div_33_Loop:
    MOVLW 33
    SUBWF math_arg1L, F
    MOVLW 0
    SUBWFB math_arg1H, F
    BN Div_33_Done
    INCF math_resL, F
    BRA Div_33_Loop
Div_33_Done:
    MOVF math_resL, W
    SUBLW 100
    BN Hum_Zero
    MOVWF humidity_percent
    BRA Logic_Step
Hum_Zero:
    CLRF humidity_percent

Logic_Step:
    CALL System_Control_Logic
    CALL Update_Display

    MOVLW 100
    CALL Delay_ms
    BRA MainLoop

; ============================================================================
; ABSTRACTION DES BOUTONS (Priorité Réseau vs Physique)
; ============================================================================
Get_Sys_State:
    MOVLW 2
    CPFSEQ wifi_sys_off
    BRA Use_Wifi_Sys
    MOVLW 0
    BTFSC PORTB, 0
    MOVLW 1
    RETURN
Use_Wifi_Sys:
    MOVF wifi_sys_off, W
    RETURN

Get_Pump_State:
    MOVLW 2
    CPFSEQ wifi_manual_pump
    BRA Use_Wifi_Pump
    MOVLW 0
    BTFSC PORTB, 1
    MOVLW 1
    RETURN
Use_Wifi_Pump:
    MOVF wifi_manual_pump, W
    RETURN

Get_Info_State:
    MOVLW 2
    CPFSEQ wifi_info_mode
    BRA Use_Wifi_Info
    MOVLW 0
    BTFSC PORTB, 2
    MOVLW 1
    RETURN
Use_Wifi_Info:
    MOVF wifi_info_mode, W
    RETURN

; ============================================================================
; COUCHE APPLICATIVE (LOGIQUE MÉTIER)
; ============================================================================
System_Control_Logic:
    ; PRIORITÉ 1 : SYSTÈME COUPÉ
    CALL Get_Sys_State
    BZ Sys_Active ; Si 0 (ON)
    
    CLRF pump_state
    CLRF manual_chrono_secL
    CLRF manual_chrono_secH
    BCF LATD, 1
    BSF LATD, 2
    BSF LATD, 0
    RETURN

Sys_Active:
    BSF LATD, 1
    BCF LATD, 2

    ; Forçage manuel
    CALL Get_Pump_State
    BNZ Sys_Auto ; Si 1 (Relâché), passage en auto
    BSF pump_state, 0
    BRA Apply_Relay

Sys_Auto:
    CLRF manual_chrono_secL
    CLRF manual_chrono_secH
    
    MOVLW 40
    CPFSLT humidity_percent
    BRA Check_Relachement
    BRA Auto_Standard

Check_Relachement:
    BTFSS pump_state, 0
    BRA Auto_Standard
    BCF pump_state, 0

Auto_Standard:
    MOVLW 40
    CPFSGT humidity_percent
    BSF pump_state, 0
    
    MOVLW 84
    CPFSLT humidity_percent
    BCF pump_state, 0

Apply_Relay:
    BTFSC pump_state, 0
    BCF LATD, 0
    BTFSS pump_state, 0
    BSF LATD, 0
    RETURN

; ============================================================================
; MISE A JOUR AFFICHAGE LCD
; ============================================================================
Update_Display:
    ; MODE 1 : SYSTÈME ÉTEINT (Veille / Erreur)
    CALL Get_Sys_State
    BZ Display_Active

    MOVLW 4 ; SLEEP_DELAY
    CPFSLT sleep_timeout_counter
    BRA Set_Bkl_Off
    BSF backlight_status, 0
    BRA Check_Btn_Err
Set_Bkl_Off:
    BCF backlight_status, 0

Check_Btn_Err:
    CALL Get_Pump_State
    BZ Show_Error ; Si appuyé (0), erreur
    CALL Get_Info_State
    BZ Show_Error
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Veille
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    BTFSC current_off_slide, 0
    PRINT_ROM Str_Zzz
    BTFSS current_off_slide, 0
    PRINT_ROM Str_PompeInact
    RETURN

Show_Error:
    CLRF sleep_timeout_counter
    BSF backlight_status, 0
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Refus
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    BTFSC seconds, 0
    PRINT_ROM Str_ActBouton
    BTFSS seconds, 0
    PRINT_ROM Str_SysSurOff
    RETURN

Display_Active:
    BSF backlight_status, 0
    CLRF sleep_timeout_counter

    ; MODE 2 : FORÇAGE MANUEL
    CALL Get_Pump_State
    BNZ Check_Info_Mode

    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Forcage
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    PRINT_ROM Str_Duree
    
    MOVFF manual_chrono_secL, math_arg1L
    MOVFF manual_chrono_secH, math_arg1H
    CALL Div_16_60
    MOVF math_resL, W
    CALL Print_2_Digits
    PRINT_ROM Str_M
    MOVF math_remL, W
    CALL Print_2_Digits
    PRINT_ROM Str_S
    RETURN

Check_Info_Mode:
    CALL Get_Info_State
    BNZ Display_Normal
    
    MOVF current_info_slide, W
    BZ Slide_0
    DECF WREG, W
    BZ Slide_1
    DECF WREG, W
    BZ Slide_2
    BRA Slide_3

Slide_0:
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Date
    MOVF day, W
    CALL Print_2_Digits
    
    BTFSC seconds, 0
    PRINT_ROM Str_Slash
    BTFSS seconds, 0
    PRINT_ROM Str_Space1
    
    MOVF month, W
    CALL Print_2_Digits
    
    BTFSC seconds, 0
    PRINT_ROM Str_Slash
    BTFSS seconds, 0
    PRINT_ROM Str_Space1
    
    PRINT_ROM Str_Year2024
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    PRINT_ROM Str_Heure
    MOVF hours, W
    CALL Print_2_Digits
    
    BTFSC seconds, 0
    PRINT_ROM Str_Colon
    BTFSS seconds, 0
    PRINT_ROM Str_Space1
    
    MOVF minutes, W
    CALL Print_2_Digits
    
    BTFSC seconds, 0
    PRINT_ROM Str_Colon
    BTFSS seconds, 0
    PRINT_ROM Str_Space1
    
    MOVF seconds, W
    CALL Print_2_Digits
    PRINT_ROM Str_Space1
    RETURN

Slide_1:
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Brut
    MOVFF raw_moistureL, math_arg1L
    MOVFF raw_moistureH, math_arg1H
    CALL Print_4_Digits
    PRINT_ROM Str_Espaces2
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    BTFSC pump_state, 0
    PRINT_ROM Str_RelaisA
    BTFSS pump_state, 0
    PRINT_ROM Str_RelaisF
    RETURN

Slide_2:
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Cible
    MOVLW 40
    CALL Print_2_Digits
    PRINT_ROM Str_Percent
    PRINT_ROM Str_Tiret
    MOVLW 85
    CALL Print_2_Digits
    PRINT_ROM Str_Percent
    PRINT_ROM Str_Space1

    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    PRINT_ROM Str_Capteur
    RETURN

Slide_3:
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Uptime
    
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    PRINT_ROM Str_Arrow
    MOVFF uptime_minutesL, math_arg1L
    MOVFF uptime_minutesH, math_arg1H
    CALL Div_16_60
    MOVFF math_resL, math_arg1L
    MOVFF math_resH, math_arg1H
    CALL Print_4_Digits
    PRINT_ROM Str_H
    MOVF math_remL, W
    CALL Print_2_Digits
    PRINT_ROM Str_M_Espace
    RETURN

Display_Normal:
    MOVLW 1
    MOVWF math_arg1L
    MOVLW 1
    CALL LCD_SetCursor
    PRINT_ROM Str_Terre
    MOVF humidity_percent, W
    CALL Print_2_Digits
    PRINT_ROM Str_Percent
    PRINT_ROM Str_Espaces4

    MOVLW 1
    MOVWF math_arg1L
    MOVLW 2
    CALL LCD_SetCursor
    BTFSC pump_state, 0
    PRINT_ROM Str_Arrosage
    BTFSS pump_state, 0
    PRINT_ROM Str_SysOK
    RETURN

; ============================================================================
; SOUS-ROUTINES D'AFFICHAGE & MATH
; ============================================================================
LCD_String_ROM:
Loop_ROM:
    TBLRD*+
    MOVF TABLAT, W
    BZ End_ROM
    CALL LCD_Char
    BRA Loop_ROM
End_ROM:
    RETURN

Print_2_Digits:
    CLRF math_arg2L
P2_Loop:
    MOVLW 10
    SUBWF WREG, W
    BN Got_Tens
    MOVWF WREG
    INCF math_arg2L, F
    BRA P2_Loop
Got_Tens:
    MOVWF math_arg2H
    MOVF math_arg2L, W
    ADDLW 0x30
    CALL LCD_Char
    MOVF math_arg2H, W
    ADDLW 0x30
    CALL LCD_Char
    RETURN

Print_4_Digits:
    CLRF math_resL
Loop_1000:
    MOVLW low(1000)
    SUBWF math_arg1L, F
    MOVLW high(1000)
    SUBWFB math_arg1H, F
    BN Done_1000
    INCF math_resL, F
    BRA Loop_1000
Done_1000:
    MOVLW low(1000)
    ADDWF math_arg1L, F
    MOVLW high(1000)
    ADDWFC math_arg1H, F
    MOVF math_resL, W
    ADDLW 0x30
    CALL LCD_Char

    CLRF math_resL
Loop_100:
    MOVLW 100
    SUBWF math_arg1L, F
    MOVLW 0
    SUBWFB math_arg1H, F
    BN Done_100
    INCF math_resL, F
    BRA Loop_100
Done_100:
    MOVLW 100
    ADDWF math_arg1L, F
    MOVLW 0
    ADDWFC math_arg1H, F
    MOVF math_resL, W
    ADDLW 0x30
    CALL LCD_Char

    MOVF math_arg1L, W
    CALL Print_2_Digits
    RETURN

Div_16_60:
    CLRF math_resL
    CLRF math_resH
Loop_Div60:
    MOVLW 60
    SUBWF math_arg1L, F
    MOVLW 0
    SUBWFB math_arg1H, F
    BN Done_Div60
    INCF math_resL, F
    BTFSC STATUS, 0
    INCF math_resH, F
    BRA Loop_Div60
Done_Div60:
    MOVLW 60
    ADDWF math_arg1L, W
    MOVWF math_remL
    RETURN

; ============================================================================
; DONNÉES STATIQUES
; ============================================================================
    PSECT constData, class=CONST, reloc=2
Str_Firmaware: DB "  FIRMWARE V3.1 ", 0
Str_Init:      DB " Initialisation ", 0
Str_Terre:     DB "TERRE : ", 0
Str_Arrosage:  DB "-> ARROSAGE...  ", 0
Str_SysOK:     DB "-> SYSTEME OK   ", 0
Str_Date:      DB "DATE: ", 0
Str_Heure:     DB "HEURE: ", 0
Str_Slash:     DB "/", 0
Str_Colon:     DB ":", 0
Str_Brut:      DB "BRUT ADC: ", 0
Str_RelaisA:   DB "RELAIS: ACTIVE  ", 0
Str_RelaisF:   DB "RELAIS: FERME   ", 0
Str_Cible:     DB "CIBLE : ", 0
Str_Tiret:     DB "-", 0
Str_Percent:   DB "%", 0
Str_Capteur:   DB "CAPTEUR : OK    ", 0
Str_Uptime:    DB "UPTIME (Heures) ", 0
Str_Refus:     DB " ACTION REFUSEE ", 0
Str_Forcage:   DB " FORCAGE MANUEL ", 0
Str_Year2024:  DB "2024", 0
Str_Veille:    DB "  MODE VEILLE   ", 0
Str_Zzz:       DB "   Zz.z.z.z..   ", 0
Str_PompeInact:DB " POMPE INACTIVE ", 0
Str_ActBouton: DB " ACTIVEZ BOUTON1", 0
Str_SysSurOff: DB " SYSTEME SUR OFF", 0
Str_Duree:     DB " DUREE: ", 0
Str_M:         DB "m ", 0
Str_S:         DB "s ", 0
Str_Arrow:     DB "-> ", 0
Str_H:         DB " h ", 0
Str_M_Espace:  DB " m  ", 0
Str_Space1:    DB " ", 0
Str_Espaces2:  DB "  ", 0
Str_Espaces4:  DB "    ", 0

    END
