; ============================================================================
; Fichier Principal de l'Ordonnanceur (main.s)
; Gère le démarrage, la boucle principale, la logique d'arrosage et l'IHM.
; ============================================================================
    PROCESSOR 18F47Q84
    #include <xc.inc>

    ; Déclarations des symboles globaux définis ici
    GLOBAL start, eff_led_green, eff_led_red, eff_pump
    GLOBAL phys_sys_off, phys_manual_pump, phys_info_mode

    ; Routines importées des autres pilotes (lcd, wifi, sensor)
    GLOBAL I2C_Init, LCD_Init, LCD_Command, LCD_Char, LCD_SetCursor, LCD_String_ROM
    GLOBAL Delay_ms, Delay_us, lcd_col, backlight_status
    
    GLOBAL Wifi_Init, Wifi_Connect_And_GET
    GLOBAL srv_sys_off, srv_manual_pump, srv_info_mode, srv_poll_interval
    GLOBAL buf_temp, buf_day, buf_month, buf_hour, buf_min

    GLOBAL Sensor_Init, Sensor_Get_Humidity, humidity_percent, raw_moisture_h, raw_moisture_l

    ; ============================================================================
    ; VARIABLES EN ACCESS RAM (Zone mémoire rapide 0x000-0x05F)
    ; ============================================================================
    PSECT udata_acs
eff_led_green:         ds 1     ; État final de la LED verte (0/1)
eff_led_red:           ds 1     ; État final de la LED rouge (0/1)
eff_pump:              ds 1     ; État final de la pompe (0/1)
eff_sys_off:           ds 1     ; État effectif du système (0=ON, 1=OFF)
eff_manual_pump:       ds 1     ; État effectif de la pompe manuelle (0=ON, 1=OFF)
eff_info_mode:         ds 1     ; État effectif de l'écran d'informations (0=ON, 1=OFF)
phys_sys_off:          ds 1     ; État physique de RB0 (0=appuyé, 1=relâché)
phys_manual_pump:      ds 1     ; État physique de RB1 (0=appuyé, 1=relâché)
phys_info_mode:        ds 1     ; État physique de RB2 (0=appuyé, 1=relâché)

tick_counter:          ds 1     ; Diviseur de fréquence pour la seconde (5 * 200ms)
local_sec:             ds 1     ; Secondes locales (0-59) pour le clignotement/horloge
uptime_min_l:          ds 1     ; Minutes d'activité totales (Uptime) - bas
uptime_min_h:          ds 1     ; Minutes d'activité - haut
slide_timer:           ds 1     ; Compteur de secondes pour le changement de slide
current_info_slide:    ds 1     ; Slide actif en mode d'informations (0-3)
current_off_slide:     ds 1     ; Slide actif en mode veille (0-1)
sleep_timeout_counter: ds 1     ; Compteur pour l'extinction du rétroéclairage
poll_counter:          ds 1     ; Compteur de secondes avant la prochaine requête

; Variables de travail temporaires
temp_val:              ds 1
temp_min:              ds 1
temp_hund:             ds 1
temp_tens:             ds 1
temp_digit:            ds 1
temp_digit_tens:       ds 1
temp_adc_l:            ds 1
temp_adc_h:            ds 1
temp_adc_th:           ds 1
temp_adc_hd:           ds 1
temp_adc_tn:           ds 1
temp_up_l:             ds 1
temp_up_h:             ds 1
temp_up_hr_l:          ds 1
temp_up_hr_h:          ds 1
manual_chrono_sec_l:   ds 1     ; Chronomètre pompe manuelle (secondes) - bas
manual_chrono_sec_h:   ds 1     ; Chronomètre pompe manuelle (secondes) - haut

; ============================================================================
; VECTEUR DE RESET (Point d'entrée physique du microcontrôleur)
; ============================================================================
    PSECT reset_vec, class=CODE, reloc=2
reset_vec:
        goto    start            ; Branchement vers l'initialisation

; ============================================================================
; VECTEUR D'INTERRUPTION
; ============================================================================
    PSECT isr_vec, class=CODE, reloc=2
isr:
        retfie  1                ; Non utilisé dans notre architecture coopérative

    PSECT code

; ----------------------------------------------------------------------------
; INITIALISATION DU SYSTÈME
; ----------------------------------------------------------------------------
start:
        ; 1. Désactiver l'analogique et configurer le Port D (Relais et LEDs)
        BANKSEL ANSELD
        clrf    ANSELD, 1       ; Port D en numérique
        BANKSEL TRISD
        clrf    TRISD, 1        ; Port D en sortie
        BANKSEL LATD
        movlw   0b00000001      ; RD0 (Relais) à 1 (Pompe coupée), RD1/RD2 à 0
        movwf   LATD, 1

        ; 2. Configurer le Port B pour les boutons (RB0, RB1, RB2)
        BANKSEL ANSELB
        clrf    ANSELB, 1       ; Port B en numérique
        BANKSEL TRISB
        movlw   0b00000111      ; RB0, RB1, RB2 en entrée
        movwf   TRISB, 1
        BANKSEL WPUB
        movlw   0b00000111      ; Activer les Pull-ups internes
        movwf   WPUB, 1

        ; 3. Initialiser les périphériques et pilotes
        call    I2C_Init        ; Configure les lignes SCL/SDA
        call    LCD_Init        ; Met sous tension et initialise le contrôleur HD44780
        call    Sensor_Init     ; Prépare le module ADC sur RA2 et l'alim RA1
        call    Wifi_Init       ; Initialise les lignes logicielles UART

        ; 4. Variables d'état par défaut
        movlw   5
        movwf   tick_counter, 0
        clrf    local_sec, 0
        clrf    uptime_min_l, 0
        clrf    uptime_min_h, 0
        clrf    slide_timer, 0
        clrf    current_info_slide, 0
        clrf    current_off_slide, 0
        clrf    sleep_timeout_counter, 0
        clrf    manual_chrono_sec_l, 0
        clrf    manual_chrono_sec_h, 0
        
        ; Premier polling immédiat (au bout de 1 seconde)
        movlw   1
        movwf   poll_counter, 0

        ; 5. Écran de démarrage (Splash Screen)
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_Splash1)
        movwf   TBLPTRL, 0
        movlw   high(Str_Splash1)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Splash1)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movlw   low(Str_Splash2)
        movwf   TBLPTRL, 0
        movlw   high(Str_Splash2)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Splash2)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        
        movlw   1500
        call    Delay_ms

; ----------------------------------------------------------------------------
; BOUCLE PRINCIPALE (COOPÉRATIVE ET TEMPS RÉEL)
; ----------------------------------------------------------------------------
Main_Loop:
        ; --- ÉTAPE A : Acquisition Analogique ---
        call    Sensor_Get_Humidity     ; Calcule humidity_percent (0-100) et raw_moisture

        ; --- ÉTAPE B : Lecture des Boutons & Synchro avec le Serveur ---
        call    Read_Inputs

        ; --- ÉTAPE C : Logique Décisionnelle ---
        call    System_Control_Logic    ; Détermine eff_pump, eff_led_green, eff_led_red et pilote LATD

        ; --- ÉTAPE D : Mise à jour de l'Affichage LCD ---
        call    Update_Display

        ; --- ÉTAPE E : Gestion des Timers Temporels (chaque seconde) ---
        decfsz  tick_counter, 1, 0      ; Décrémente le tick (200ms)
        bra     Delay_And_Next
        
        ; Une seconde s'est écoulée !
        movlw   5
        movwf   tick_counter, 0
        
        ; Incrémenter les secondes locales (clignotement)
        incf    local_sec, 1, 0
        movf    local_sec, 0, 0
        sublw   60
        bnz     Check_Slide_Timer
        clrf    local_sec, 0
        
        ; Incrémenter l'uptime (minutes)
        incf    uptime_min_l, 1, 0
        movlw   0
        addwfc  uptime_min_h, 1, 0
        
Check_Slide_Timer:
        ; Diaporama d'infos : incrémenter slide_timer
        incf    slide_timer, 1, 0
        movf    slide_timer, 0, 0
        sublw   4                       ; 4 secondes par slide
        bnz     Check_Sleep_Timer
        clrf    slide_timer, 0
        
        ; Rotation des diaporamas
        incf    current_info_slide, 1, 0
        movf    current_info_slide, 0, 0
        sublw   4
        bnz     Rotate_Off_Slide
        clrf    current_info_slide, 0
Rotate_Off_Slide:
        incf    current_off_slide, 1, 0
        movf    current_off_slide, 0, 0
        sublw   2
        bnz     Check_Sleep_Timer
        clrf    current_off_slide, 0

Check_Sleep_Timer:
        ; Si le système est éteint (eff_sys_off = 1), incrémenter sleep_timeout_counter
        movf    eff_sys_off, 0, 0
        xorlw   1
        bnz     Reset_Sleep_Timer
        movf    sleep_timeout_counter, 0, 0
        sublw   4
        bz      Chrono_Pump_Check       ; Éviter dépassement
        incf    sleep_timeout_counter, 1, 0
        bra     Chrono_Pump_Check
Reset_Sleep_Timer:
        clrf    sleep_timeout_counter, 0

Chrono_Pump_Check:
        ; Si la pompe tourne en forçage manuel local, compter les secondes
        movf    eff_sys_off, 0, 0
        bnz     Reset_Chrono
        movf    eff_manual_pump, 0, 0
        bnz     Reset_Chrono
        movf    eff_pump, 0, 0
        bz      Reset_Chrono
        
        ; Incrémenter le chronomètre
        incf    manual_chrono_sec_l, 1, 0
        movlw   0
        addwfc  manual_chrono_sec_h, 1, 0
        bra     Decrement_Poll_Counter
Reset_Chrono:
        clrf    manual_chrono_sec_l, 0
        clrf    manual_chrono_sec_h, 0

Decrement_Poll_Counter:
        ; Décrémenter le compteur de secondes avant polling WiFi
        decfsz  poll_counter, 1, 0
        bra     Delay_And_Next
        
        ; --- ÉTAPE F : Requête WiFi / Synchro Serveur ---
        call    Wifi_Connect_And_GET
        
        ; Réinitialiser la base de temps de polling depuis la valeur du serveur
        movf    srv_poll_interval, 0, 0
        movwf   poll_counter, 0
        
        ; En cas de succès (Carry = 0), réinitialiser les secondes locales
        btfss   STATUS, 0, 0
        clrf    local_sec, 0

Delay_And_Next:
        ; Capteur prend ~110ms, on attend ~90ms pour boucler en ~200ms
        movlw   90
        call    Delay_ms
        bra     Main_Loop

; ----------------------------------------------------------------------------
; LECTURE DES ENTRÉES AVEC PRIORITÉS SERVEUR
; ----------------------------------------------------------------------------
Read_Inputs:
        ; --- ÉTAPE 1 : Lire les entrées physiques de PORTB ---
        BANKSEL PORTB
        
        ; 1.1 Lire RB0 (System Off)
        clrf    phys_sys_off, 0
        btfsc   PORTB, 0, 1     ; Si RB0 est haut (1, relâché), btfsc ne saute pas
        incf    phys_sys_off, 1, 0 ; Sinon (relâché), phys_sys_off = 1

        ; 1.2 Lire RB1 (Manual Pump)
        clrf    phys_manual_pump, 0
        btfsc   PORTB, 1, 1     ; Si RB1 est haut (1, relâché)
        incf    phys_manual_pump, 1, 0 ; phys_manual_pump = 1

        ; 1.3 Lire RB2 (Info Mode)
        clrf    phys_info_mode, 0
        btfsc   PORTB, 2, 1     ; Si RB2 est haut (1, relâché)
        incf    phys_info_mode, 1, 0 ; phys_info_mode = 1

        ; --- ÉTAPE 2 : Déterminer les états effectifs selon les priorités ---
        
        ; 2.1 Système Général (eff_sys_off) : 0=ON (actif), 1=OFF (éteint)
        movf    phys_sys_off, 0, 0
        bz      SysOff_Phys_On  ; Si phys_sys_off est 0 (appuyé), il a la priorité absolue -> ON (0)
        
        ; Sinon (relâché physiquement), on vérifie le serveur
        movf    srv_sys_off, 0, 0
        xorlw   0               ; Est-ce forcé à ON en ligne ?
        bz      SysOff_Online_On
        
        ; Par défaut (ni appuyé physiquement, ni ON en ligne) -> OFF (1)
        movlw   1
        movwf   eff_sys_off, 0
        bra     Check_ManualPump
SysOff_Phys_On:
SysOff_Online_On:
        clrf    eff_sys_off, 0

Check_ManualPump:
        ; 2.2 Pompe Manuelle (eff_manual_pump) : 0=ON (active), 1=OFF (inactive)
        movf    phys_manual_pump, 0, 0
        bz      ManualPump_Phys_On ; Si phys_manual_pump est 0 (appuyé), priorité -> ON (0)
        
        movf    srv_manual_pump, 0, 0
        xorlw   0               ; Est-ce forcé à ON en ligne ?
        bz      ManualPump_Online_On
        
        ; Par défaut -> OFF (1)
        movlw   1
        movwf   eff_manual_pump, 0
        bra     Check_InfoMode
ManualPump_Phys_On:
ManualPump_Online_On:
        clrf    eff_manual_pump, 0

Check_InfoMode:
        ; 2.3 Écran d'informations (eff_info_mode) : 0=ON (diaporama), 1=OFF (normal)
        movf    phys_info_mode, 0, 0
        bz      InfoMode_Phys_On ; Si phys_info_mode est 0 (appuyé), priorité -> ON (0)
        
        movf    srv_info_mode, 0, 0
        xorlw   0               ; Est-ce forcé à ON en ligne ?
        bz      InfoMode_Online_On
        
        ; Par défaut -> OFF (1)
        movlw   1
        movwf   eff_info_mode, 0
        return
InfoMode_Phys_On:
InfoMode_Online_On:
        clrf    eff_info_mode, 0
        return

; ----------------------------------------------------------------------------
; LOGIQUE DÉCISIONNELLE DE CONTRÔLE (POMPE ET LEDS)
; ----------------------------------------------------------------------------
System_Control_Logic:
        ; --- PRIORITÉ 1 : SYSTÈME ÉTEINT ---
        movf    eff_sys_off, 0, 0
        xorlw   1
        bnz     Sys_Active
        
        clrf    eff_pump, 0
        clrf    eff_led_green, 0
        movlw   1
        movwf   eff_led_red, 0
        
        ; Force les sorties physiques
        BANKSEL LATD
        bsf     LATD, 0, 1      ; Coupe le relais pompe (RD0=1)
        bcf     LATD, 1, 1      ; Éteint la LED verte (RD1=0)
        bsf     LATD, 2, 1      ; Allume la LED rouge (RD2=1)
        return

Sys_Active:
        ; --- PRIORITÉ 2 : SYSTÈME ALLUMÉ ---
        movlw   1
        movwf   eff_led_green, 0
        clrf    eff_led_red, 0

        ; Forçage Manuel de la pompe
        movf    eff_manual_pump, 0, 0
        bnz     Sys_Auto
        movlw   1
        movwf   eff_pump, 0
        bra     Apply_Actuators

Sys_Auto:
        ; Logique automatique (Seuils 40% et 85%)
        movf    humidity_percent, 0, 0
        sublw   40              ; W = 40 - humidity_percent
        bnc     Check_Off
        movlw   1               ; Humidité <= 40% -> Pompe ON
        movwf   eff_pump, 0
        bra     Apply_Actuators
Check_Off:
        movf    humidity_percent, 0, 0
        sublw   84              ; W = 84 - humidity_percent
        bc      Apply_Actuators ; Si < 85%, garde l'état actuel de eff_pump
        clrf    eff_pump, 0     ; Humidité >= 85% -> Pompe OFF

Apply_Actuators:
        ; Application physique sur les broches du Port D
        BANKSEL LATD
        movf    eff_pump, 0, 0
        bz      Phys_Pump_Off
        bcf     LATD, 0, 1      ; Pompe ON (Relais actif à l'état bas)
        bra     Phys_LED_Green
Phys_Pump_Off:
        bsf     LATD, 0, 1      ; Pompe OFF
Phys_LED_Green:
        movf    eff_led_green, 0, 0
        bz      Phys_Green_Off
        bsf     LATD, 1, 1      ; LED Verte ON
        bra     Phys_LED_Red
Phys_Green_Off:
        bcf     LATD, 1, 1
Phys_LED_Red:
        movf    eff_led_red, 0, 0
        bz      Phys_Red_Off
        bsf     LATD, 2, 1      ; LED Rouge ON
        return
Phys_Red_Off:
        bcf     LATD, 2, 1
        return

; ----------------------------------------------------------------------------
; RENDU VISUEL SUR L'ÉCRAN LCD
; ----------------------------------------------------------------------------
Update_Display:
        ; --- MODE 1 : SYSTÈME ÉTEINT (Veille) ---
        movf    eff_sys_off, 0, 0
        xorlw   1
        bnz     Display_Active
        
        ; Gestion du rétroéclairage
        movf    sleep_timeout_counter, 0, 0
        sublw   4
        bnz     Keep_Backlight_ON
        clrf    backlight_status, 0     ; Rétroéclairage OFF
        bra     Check_Veille_Action
Keep_Backlight_ON:
        movlw   0x08
        movwf   backlight_status, 0     ; Rétroéclairage ON

Check_Veille_Action:
        ; Si un bouton est manipulé pendant la veille
        movf    eff_manual_pump, 0, 0
        bz      Display_Refused
        movf    eff_info_mode, 0, 0
        bz      Display_Refused
        
        ; Rendu veille classique
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_ModeVeille)
        movwf   TBLPTRL, 0
        movlw   high(Str_ModeVeille)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_ModeVeille)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movf    current_off_slide, 0, 0
        bz      Display_Zz
        movlw   low(Str_PompeInactive)
        movwf   TBLPTRL, 0
        movlw   high(Str_PompeInactive)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_PompeInactive)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return
Display_Zz:
        movlw   low(Str_Zz)
        movwf   TBLPTRL, 0
        movlw   high(Str_Zz)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Zz)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return

Display_Refused:
        clrf    sleep_timeout_counter, 0
        movlw   0x08
        movwf   backlight_status, 0     ; Réactiver rétroéclairage
        
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_ActionRefusee)
        movwf   TBLPTRL, 0
        movlw   high(Str_ActionRefusee)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_ActionRefusee)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        
        movf    local_sec, 0, 0
        andlw   1                       ; Clignotement
        bz      Display_SysOff_Msg
        movlw   low(Str_ActivezB1)
        movwf   TBLPTRL, 0
        movlw   high(Str_ActivezB1)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_ActivezB1)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return
Display_SysOff_Msg:
        movlw   low(Str_SysSurOff)
        movwf   TBLPTRL, 0
        movlw   high(Str_SysSurOff)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_SysSurOff)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return

Display_Active:
        movlw   0x08
        movwf   backlight_status, 0     ; Allumé si actif
        
        ; --- MODE 2 : FORÇAGE MANUEL ---
        movf    eff_manual_pump, 0, 0
        bnz     Display_Check_Info
        
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_ForcMan)
        movwf   TBLPTRL, 0
        movlw   high(Str_ForcMan)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_ForcMan)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movlw   low(Str_Durie)
        movwf   TBLPTRL, 0
        movlw   high(Str_Durie)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Durie)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        ; Calculer les minutes/secondes depuis manual_chrono_sec
        movf    manual_chrono_sec_l, 0, 0
        movwf   temp_val, 0
        clrf    temp_min, 0
Chrono_Min_Loop:
        movlw   60
        subwf   temp_val, 0, 0
        bnc     Chrono_Min_Done
        movwf   temp_val, 0
        incf    temp_min, 1, 0
        bra     Chrono_Min_Loop
Chrono_Min_Done:
        movf    temp_min, 0, 0
        call    Print_2_Digits
        movlw   'm'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movf    temp_val, 0, 0
        call    Print_2_Digits
        movlw   's'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        return

Display_Check_Info:
        ; --- MODE 3 : DIAPORAMA D'INFORMATIONS ---
        movf    eff_info_mode, 0, 0
        bnz     Display_Normal_Dash
        
        movf    current_info_slide, 0, 0
        bz      Display_Slide0
        xorlw   1
        bz      Display_Slide1
        xorlw   3                       ; Comparaison directe
        bz      Display_Slide2
        bra     Display_Slide3

Display_Slide0:
        ; Slide 0 : Horloge et Date
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_DatePrefix)
        movwf   TBLPTRL, 0
        movlw   high(Str_DatePrefix)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_DatePrefix)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        
        movf    buf_day, 0, 0
        call    LCD_Char
        movf    buf_day+1, 0, 0
        call    LCD_Char
        movlw   '/'
        call    LCD_Char
        movf    buf_month, 0, 0
        call    LCD_Char
        movf    buf_month+1, 0, 0
        call    LCD_Char
        movlw   '/'
        call    LCD_Char
        movlw   '2'
        call    LCD_Char
        movlw   '0'
        call    LCD_Char
        movlw   '2'
        call    LCD_Char
        movlw   '6'
        call    LCD_Char

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movlw   low(Str_HeurePrefix)
        movwf   TBLPTRL, 0
        movlw   high(Str_HeurePrefix)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_HeurePrefix)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        
        movf    local_sec, 0, 0
        andlw   1
        bz      Display_Time_Blank
        
        movf    buf_hour, 0, 0
        call    LCD_Char
        movf    buf_hour+1, 0, 0
        call    LCD_Char
        movlw   ':'
        call    LCD_Char
        movf    buf_min, 0, 0
        call    LCD_Char
        movf    buf_min+1, 0, 0
        call    LCD_Char
        movlw   ':'
        call    LCD_Char
        movf    local_sec, 0, 0
        call    Print_2_Digits
        movlw   ' '
        call    LCD_Char
        return
Display_Time_Blank:
        movf    buf_hour, 0, 0
        call    LCD_Char
        movf    buf_hour+1, 0, 0
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movf    buf_min, 0, 0
        call    LCD_Char
        movf    buf_min+1, 0, 0
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movf    local_sec, 0, 0
        call    Print_2_Digits
        movlw   ' '
        call    LCD_Char
        return

Display_Slide1:
        ; Slide 1 : Diagnostic
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_BrutAdc)
        movwf   TBLPTRL, 0
        movlw   high(Str_BrutAdc)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_BrutAdc)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        
        call    Print_ADC_Decimal

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movf    eff_pump, 0, 0
        bz      Display_RelaisFerme
        movlw   low(Str_RelaisActive)
        movwf   TBLPTRL, 0
        movlw   high(Str_RelaisActive)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_RelaisActive)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return
Display_RelaisFerme:
        movlw   low(Str_RelaisFerme)
        movwf   TBLPTRL, 0
        movlw   high(Str_RelaisFerme)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_RelaisFerme)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return

Display_Slide2:
        ; Slide 2 : Configuration Cible
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_Cible)
        movwf   TBLPTRL, 0
        movlw   high(Str_Cible)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Cible)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        movlw   low(Str_CapteurOk)
        movwf   TBLPTRL, 0
        movlw   high(Str_CapteurOk)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CapteurOk)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return

Display_Slide3:
        ; Slide 3 : Maintenance Uptime
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_UptimeTitle)
        movwf   TBLPTRL, 0
        movlw   high(Str_UptimeTitle)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_UptimeTitle)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM

        ; Calculer hours = uptime_min / 60, minutes = uptime_min % 60
        movf    uptime_min_l, 0, 0
        movwf   temp_up_l, 0
        movf    uptime_min_h, 0, 0
        movwf   temp_up_h, 0
        clrf    temp_up_hr_l, 0
        clrf    temp_up_hr_h, 0
Up_Min_Loop:
        movlw   60
        subwf   temp_up_l, 0, 0
        movf    temp_up_h, 0, 0
        subwfb  STATUS, 0, 0
        bnc     Up_Min_Done
        
        movlw   60
        subwf   temp_up_l, 1, 0
        movlw   0
        subwfb  temp_up_h, 1, 0
        
        incf    temp_up_hr_l, 1, 0
        movlw   0
        addwfc  temp_up_hr_h, 1, 0
        bra     Up_Min_Loop
Up_Min_Done:
        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        
        movlw   '-'
        call    LCD_Char
        movlw   '>'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        
        call    Print_16bit_Decimal
        
        movlw   ' '
        call    LCD_Char
        movlw   'h'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        
        movf    temp_up_l, 0, 0
        call    Print_2_Digits
        
        movlw   ' '
        call    LCD_Char
        movlw   'm'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        return

Display_Normal_Dash:
        ; --- MODE 4 : AFFICHAGE NORMAL ---
        movlw   1
        movwf   lcd_col, 0
        movlw   1
        call    LCD_SetCursor
        movlw   low(Str_Terre)
        movwf   TBLPTRL, 0
        movlw   high(Str_Terre)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Terre)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        
        ; Formater et afficher l'humidité (%3u)
        movf    humidity_percent, 0, 0
        movwf   temp_val, 0
        clrf    temp_hund, 0
        clrf    temp_tens, 0
Dash_Hund_Loop:
        movlw   100
        subwf   temp_val, 0, 0
        bnc     Dash_Tens_Loop
        movwf   temp_val, 0
        incf    temp_hund, 1, 0
        bra     Dash_Hund_Loop
Dash_Tens_Loop:
        movlw   10
        subwf   temp_val, 0, 0
        bnc     Dash_Ones_Done
        movwf   temp_val, 0
        incf    temp_tens, 1, 0
        bra     Dash_Tens_Loop
Dash_Ones_Done:
        ; Centaines
        movf    temp_hund, 0, 0
        bz      Dash_Space_Hund
        addlw   '0'
        call    LCD_Char
        bra     Dash_Print_Tens
Dash_Space_Hund:
        movlw   ' '
        call    LCD_Char
Dash_Print_Tens:
        movf    temp_hund, 0, 0
        bnz     Dash_Tens_Dig
        movf    temp_tens, 0, 0
        bz      Dash_Space_Tens
Dash_Tens_Dig:
        movf    temp_tens, 0, 0
        addlw   '0'
        call    LCD_Char
        bra     Dash_Print_Ones
Dash_Space_Tens:
        movlw   ' '
        call    LCD_Char
Dash_Print_Ones:
        movf    temp_val, 0, 0
        addlw   '0'
        call    LCD_Char
        
        movlw   '%'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movlw   ' '
        call    LCD_Char

        movlw   1
        movwf   lcd_col, 0
        movlw   2
        call    LCD_SetCursor
        
        movf    eff_pump, 0, 0
        bz      Dash_SystemeOk
        movlw   low(Str_Arrosage)
        movwf   TBLPTRL, 0
        movlw   high(Str_Arrosage)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Arrosage)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return
Dash_SystemeOk:
        movlw   low(Str_SystemeOk)
        movwf   TBLPTRL, 0
        movlw   high(Str_SystemeOk)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_SystemeOk)
        movwf   TBLPTRU, 0
        call    LCD_String_ROM
        return

; ----------------------------------------------------------------------------
; UTILS : AFFICHAGE DE DEUX CHIFFRES DÉCIMAUX
; ----------------------------------------------------------------------------
Print_2_Digits:
        movwf   temp_digit, 0
        clrf    temp_digit_tens, 0
P2D_Tens_Loop:
        movlw   10
        subwf   temp_digit, 0, 0
        bnc     P2D_Tens_Done
        movwf   temp_digit, 0
        incf    temp_digit_tens, 1, 0
        bra     P2D_Tens_Loop
P2D_Tens_Done:
        movf    temp_digit_tens, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_digit, 0, 0
        addlw   '0'
        call    LCD_Char
        return

; ----------------------------------------------------------------------------
; UTILS : AFFICHAGE DE LA VALEUR BRUTE ADC SUR 4 CHIFFRES
; ----------------------------------------------------------------------------
Print_ADC_Decimal:
        movf    raw_moisture_l, 0, 0
        movwf   temp_adc_l, 0
        movf    raw_moisture_h, 0, 0
        movwf   temp_adc_h, 0
        
        clrf    temp_adc_th, 0
        clrf    temp_adc_hd, 0
        clrf    temp_adc_tn, 0
P_Th_Loop:
        movlw   low(1000)
        subwf   temp_adc_l, 0, 0
        movlw   high(1000)
        subwfb  temp_adc_h, 0, 0
        bnc     P_Hd_Loop
        
        movlw   low(1000)
        subwf   temp_adc_l, 1, 0
        movlw   high(1000)
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_th, 1, 0
        bra     P_Th_Loop
P_Hd_Loop:
        movlw   100
        subwf   temp_adc_l, 0, 0
        movf    temp_adc_h, 0, 0
        subwfb  STATUS, 0, 0
        bnc     P_Tn_Loop
        
        movlw   100
        subwf   temp_adc_l, 1, 0
        movlw   0
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_hd, 1, 0
        bra     P_Hd_Loop
P_Tn_Loop:
        movlw   10
        subwf   temp_adc_l, 0, 0
        movf    temp_adc_h, 0, 0
        subwfb  STATUS, 0, 0
        bnc     P_Ones_Done
        
        movlw   10
        subwf   temp_adc_l, 1, 0
        movlw   0
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_tn, 1, 0
        bra     P_Tn_Loop
P_Ones_Done:
        movf    temp_adc_th, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_hd, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_tn, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_l, 0, 0
        addlw   '0'
        call    LCD_Char
        
        movlw   ' '
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        return

; ----------------------------------------------------------------------------
; UTILS : AFFICHAGE D'UN NOMBRE 16 BITS DE 4 CHIFFRES
; ----------------------------------------------------------------------------
Print_16bit_Decimal:
        movf    temp_up_hr_l, 0, 0
        movwf   temp_adc_l, 0
        movf    temp_up_hr_h, 0, 0
        movwf   temp_adc_h, 0
        
        clrf    temp_adc_th, 0
        clrf    temp_adc_hd, 0
        clrf    temp_adc_tn, 0
P16_Th_Loop:
        movlw   low(1000)
        subwf   temp_adc_l, 0, 0
        movlw   high(1000)
        subwfb  temp_adc_h, 0, 0
        bnc     P16_Hd_Loop
        
        movlw   low(1000)
        subwf   temp_adc_l, 1, 0
        movlw   high(1000)
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_th, 1, 0
        bra     P16_Th_Loop
P16_Hd_Loop:
        movlw   100
        subwf   temp_adc_l, 0, 0
        movf    temp_adc_h, 0, 0
        subwfb  STATUS, 0, 0
        bnc     P16_Tn_Loop
        
        movlw   100
        subwf   temp_adc_l, 1, 0
        movlw   0
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_hd, 1, 0
        bra     P16_Hd_Loop
P16_Tn_Loop:
        movlw   10
        subwf   temp_adc_l, 0, 0
        movf    temp_adc_h, 0, 0
        subwfb  STATUS, 0, 0
        bnc     P16_Ones_Done
        
        movlw   10
        subwf   temp_adc_l, 1, 0
        movlw   0
        subwfb  temp_adc_h, 1, 0
        incf    temp_adc_tn, 1, 0
        bra     P16_Tn_Loop
P16_Ones_Done:
        movf    temp_adc_th, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_hd, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_tn, 0, 0
        addlw   '0'
        call    LCD_Char
        movf    temp_adc_l, 0, 0
        addlw   '0'
        call    LCD_Char
        return

; ============================================================================
; STRINGS ROM
; ============================================================================
Str_Splash1:       db '  FIRMWARE V3.1 ',0
Str_Splash2:       db ' Initialisation ',0
Str_ModeVeille:    db '  MODE VEILLE   ',0
Str_PompeInactive: db ' POMPE INACTIVE ',0
Str_Zz:            db '   Zz.z.z.z..   ',0
Str_ActionRefusee: db ' ACTION REFUSEE ',0
Str_ActivezB1:     db ' ACTIVEZ BOUTON1',0
Str_SysSurOff:     db ' SYSTEME SUR OFF',0
Str_ForcMan:       db ' FORCAGE MANUEL ',0
Str_Durie:         db ' DURIE: ',0
Str_DatePrefix:    db 'DATE: ',0
Str_HeurePrefix:   db 'HEURE: ',0
Str_BrutAdc:       db 'BRUT ADC: ',0
Str_RelaisActive:  db 'RELAIS: ACTIVE  ',0
Str_RelaisFerme:   db 'RELAIS: FERME   ',0
Str_Cible:         db 'CIBLE : 40%-85% ',0
Str_CapteurOk:     db 'CAPTEUR : OK    ',0
Str_UptimeTitle:   db 'UPTIME (Heures) ',0
Str_Terre:         db 'TERRE : ',0
Str_Arrosage:      db '-> ARROSAGE...  ',0
Str_SystemeOk:     db '-> SYSTEME OK   ',0

        end     reset_vec