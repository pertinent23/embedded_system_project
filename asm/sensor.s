; ============================================================================
; Pilote Capteur d'Humidité du Sol (sensor.s)
; Gère l'acquisition ADC et la conversion en pourcentage.
; ============================================================================
    PROCESSOR 18F47Q84
    #include <xc.inc>

    ; Export des fonctions et variables globales
    GLOBAL Sensor_Init, Sensor_Get_Humidity
    GLOBAL humidity_percent, raw_moisture_h, raw_moisture_l
    GLOBAL Delay_ms, Delay_us

    ; ============================================================================
    ; VARIABLES EN ACCESS RAM (Zone mémoire rapide 0x000-0x05F)
    ; ============================================================================
    PSECT udata_acs
humidity_percent: ds 1          ; Humidité calculée en % (0-100)
raw_moisture_l:   ds 1          ; Valeur brute basse de l'ADC
raw_moisture_h:   ds 1          ; Valeur brute haute de l'ADC

; Variables locales d'acquisition et calcul
accum_l:          ds 1          ; Accumulateur 24 bits
accum_h:          ds 1
accum_u:          ds 1
sample_cnt:       ds 1          ; Compteur d'échantillons
diff_l:           ds 1          ; Différence pour calcul pourcentage
diff_h:           ds 1

    ; ============================================================================
    ; CODE DE L'APPLICATION
    ; ============================================================================
    PSECT code

; ----------------------------------------------------------------------------
; INITIALISATION DU CAPTEUR ET DE L'ADC
; ----------------------------------------------------------------------------
Sensor_Init:
        ; 1. Configurer la broche de commande d'alimentation (RA1)
        BANKSEL ANSELA
        bcf     ANSELA, 1, 1    ; RA1 en mode numérique
        bcf     TRISA, 1, 1     ; RA1 en sortie
        BANKSEL LATA
        bcf     LATA, 1, 1      ; Coupe l'alimentation au démarrage
        
        ; 2. Configurer la broche analogique de mesure (RA2)
        BANKSEL ANSELA
        bsf     ANSELA, 2, 1    ; RA2 en mode analogique (ANA2)
        bsf     TRISA, 2, 1     ; RA2 en entrée
        
        ; 3. Configurer le module ADC (ADCC)
        BANKSEL ADCON0
        clrf    ADCON0, 1
        clrf    ADCON1, 1
        clrf    ADCON2, 1
        clrf    ADCON3, 1
        
        ; Activer l'ADC, horloge ADCRC, résultat justifié à droite (FM = 0b11)
        ; ADCON0 = 0b10101100 (ON=1, CONT=0, CS=1, FM=11)
        movlw   0b10101100
        movwf   ADCON0, 1
        
        ; Tensions de référence sur VDD (5V) et VSS (0V)
        clrf    ADREF, 1
        
        ; Sélectionner le canal ANA2 (RA2) -> ADPCH = 0x02
        movlw   2
        movwf   ADPCH, 1
        
        ; Temps d'acquisition -> ADACQ = 0x20
        movlw   0x20
        movwf   ADACQ, 1
        return

; ----------------------------------------------------------------------------
; LECTURE BRUTE ET CALCUL DE L'HUMIDITÉ
; ----------------------------------------------------------------------------
; Effectue 64 mesures, fait la moyenne, et convertit en % (0-100)
Sensor_Get_Humidity:
        ; Alimenter le capteur (RA1 = 1)
        BANKSEL LATA
        bsf     LATA, 1, 1
        
        ; Attendre 50ms pour stabiliser le capteur
        movlw   50
        call    Delay_ms
        
        ; Initialiser l'accumulateur 24 bits
        clrf    accum_l, 0
        clrf    accum_h, 0
        clrf    accum_u, 0
        
        ; Compteur d'échantillons (64)
        movlw   64
        movwf   sample_cnt, 0

Read_Loop:
        ; Lancer la conversion ADC (Bit GO = 0 de ADCON0)
        BANKSEL ADCON0
        bsf     ADCON0, 0, 1
Wait_ADC:
        btfsc   ADCON0, 0, 1    ; Attend la fin de la conversion (GO repasse à 0)
        bra     Wait_ADC
        
        ; Accumuler le résultat (ADRESH:ADRESL)
        movf    ADRESL, 0, 1
        addwf   accum_l, 1, 0
        movf    ADRESH, 0, 1
        addwfc  accum_h, 1, 0
        movlw   0
        addwfc  accum_u, 1, 0
        
        ; Attendre 100us entre chaque mesure
        movlw   100
        call    Delay_us
        
        decfsz  sample_cnt, 1, 0
        bra     Read_Loop
        
        ; Couper l'alimentation du capteur (RA1 = 0)
        BANKSEL LATA
        bcf     LATA, 1, 1
        
        ; Diviser par 64 (Décalage à droite de 6 bits)
        movlw   6
        movwf   sample_cnt, 0
Shift_Loop:
        bcf     STATUS, 0, 0    ; Clear Carry
        rrcf    accum_u, 1, 0
        rrcf    accum_h, 1, 0
        rrcf    accum_l, 1, 0
        decfsz  sample_cnt, 1, 0
        bra     Shift_Loop
        
        ; Sauvegarder la valeur brute moyenne
        movf    accum_l, 0, 0
        movwf   raw_moisture_l, 0
        movf    accum_h, 0, 0
        movwf   raw_moisture_h, 0
        
        ; --- CONVERSION EN POURCENTAGE ---
        ; Formule : Humidité = (4095 - raw_moisture) / 33
        ; 1. Calculer 4095 - raw_moisture
        movlw   0xFF            ; 4095 bas (0xFF)
        subwf   raw_moisture_l, 0, 0 ; W = 0xFF - raw_moisture_l
        movwf   diff_l, 0
        
        movlw   0x0F            ; 4095 haut (0x0F)
        subwfb  raw_moisture_h, 0, 0 ; W = 0x0F - raw_moisture_h - Borrow
        movwf   diff_h, 0
        
        ; Si diff est négatif (raw_moisture > 4095), diff = 0
        btfsc   diff_h, 7, 0
        bra     Set_Zero_Humidity
        
        ; 2. Diviser diff (16 bits) par 33 via soustraction successive
        clrf    humidity_percent, 0
Div_Loop:
        ; Comparer diff avec 33
        movlw   33
        subwf   diff_l, 0, 0    ; W = diff_l - 33
        movf    diff_h, 0, 0
        subwfb  STATUS, 0, 0    ; Soustrait l'emprunt (Borrow)
        bnc     Div_Done        ; Si négatif, division terminée
        
        ; Effectuer la soustraction réelle
        movlw   33
        subwf   diff_l, 1, 0
        movlw   0
        subwfb  diff_h, 1, 0
        
        incf    humidity_percent, 1, 0
        bra     Div_Loop

Div_Done:
        ; Limiter la valeur maximale à 100%
        movlw   100
        subwf   humidity_percent, 0, 0
        bnc     Cap_Done
        movlw   100
        movwf   humidity_percent, 0
Cap_Done:
        movf    humidity_percent, 0, 0
        return

Set_Zero_Humidity:
        clrf    humidity_percent, 0
        movf    humidity_percent, 0, 0
        return
