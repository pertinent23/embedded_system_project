PROCESSOR 18F47Q84               ; Spécifie le microcontrôleur PIC18F47Q84

; Inclut les définitions des registres et des broches
#include <xc.inc>

; ============================================================================
; EXPORT DES FONCTIONS GLOBALES
; ============================================================================
    GLOBAL I2C_Init, I2C_Start, I2C_Stop, I2C_Write
    GLOBAL LCD_Init, LCD_Command, LCD_Char, LCD_SetCursor, LCD_String_ROM
    GLOBAL Delay_ms, Delay_us
    GLOBAL lcd_col, backlight_status

; ============================================================================
; VARIABLES EN ACCESS RAM (Zone mémoire rapide 0x000-0x05F, pas besoin de BANKSEL)
; ============================================================================
    PSECT udata_acs
delay_cnt1:       ds 1           ; Compteur de boucle pour Delay_us
delay_cnt2:       ds 1           ; Compteur de boucle 1 pour Delay_ms
delay_cnt3:       ds 1           ; Compteur de boucle 2 pour Delay_ms
i2c_data:         ds 1           ; Donnée à envoyer sur l'I2C
i2c_bit_cnt:      ds 1           ; Compteur de bits pour l'I2C (8 bits)
lcd_data:         ds 1           ; Donnée LCD combinant les bits de poids fort, RS et Backlight
lcd_rs:           ds 1           ; Registre de sélection RS (0 = commande, 1 = caractère)
backlight_status: ds 1           ; Statut du rétroéclairage (0x08 = allumé, 0x00 = éteint)
lcd_temp:         ds 1           ; Stockage temporaire du caractère/commande à envoyer
lcd_col:          ds 1           ; Colonne pour LCD_SetCursor

; ============================================================================
; SECTEUR DE CODE (Relocalisable)
; ============================================================================
    PSECT code

; ----------------------------------------------------------------------------
; ROUTINES DE GESTION DU TEMPS (DÉLAIS CALIBRÉS À 64 MHz)
; ----------------------------------------------------------------------------

; @brief Attend WREG microsecondes (max 255)
Delay_us:
        movwf   delay_cnt1, 0    ; Charge W dans le compteur us (dans l'Access Bank)
Delay_us_loop:
        nop                      ; 1 cycle d'instruction
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        nop                      ; 1 cycle
        decfsz  delay_cnt1, 1, 0 ; 1 cycle (décrémente, résultat dans file, saute si 0)
        bra     Delay_us_loop    ; 2 cycles si branchement
        return                   ; 2 cycles de retour

; @brief Attend WREG millisecondes (max 255)
Delay_ms:
        movwf   delay_cnt3, 0    ; Charge W dans le compteur de ms
Delay_ms_loop:
        movlw   16               ; Charge 16 (16 * 1000 = 16000 cycles pour 1ms à 64MHz)
        movwf   delay_cnt2, 0    ; Charge dans le compteur intermédiaire
Delay_ms_inner1:
        movlw   250              ; Charge 250 dans le compteur interne
        movwf   delay_cnt1, 0
Delay_ms_inner2:
        decfsz  delay_cnt1, 1, 0 ; 1 cycle (2 si saut)
        bra     Delay_ms_inner2  ; 2 cycles (la boucle interne dure 3 cycles * 250 = 750 cycles)
        decfsz  delay_cnt2, 1, 0 ; 1 cycle
        bra     Delay_ms_inner1  ; 2 cycles
        decfsz  delay_cnt3, 1, 0 ; 1 cycle
        bra     Delay_ms_loop    ; 2 cycles
        return                   ; Retour

; ----------------------------------------------------------------------------
; PILOTES I2C (Bit-Banging) sur RC3 (SCL) et RC4 (SDA)
; ----------------------------------------------------------------------------

; @brief Initialise les broches I2C
I2C_Init:
        BANKSEL ANSELC           ; Sélectionne la banque du Port C (Bank 4)
        bcf     ANSELC, 3, 1     ; RC3 en mode numérique
        bcf     ANSELC, 4, 1     ; RC4 en mode numérique
        bcf     LATC, 3, 1       ; Force la sortie SCL à 0V
        bcf     LATC, 4, 1       ; Force la sortie SDA à 0V
        bsf     TRISC, 3, 1      ; SCL en entrée (relâché à l'état haut par pull-up)
        bsf     TRISC, 4, 1      ; SDA en entrée (relâché à l'état haut par pull-up)
        return

; @brief Génère la condition de START
I2C_Start:
        BANKSEL TRISC            ; Sélectionne la banque 4
        bcf     TRISC, 4, 1      ; SDA = 0 (Tire la ligne à la masse)
        movlw   5                ; Attend 5 us
        call    Delay_us
        bcf     TRISC, 3, 1      ; SCL = 0 (Tire la ligne d'horloge à la masse)
        movlw   5                ; Attend 5 us
        call    Delay_us
        return

; @brief Génère la condition de STOP
I2C_Stop:
        BANKSEL TRISC            ; Sélectionne la banque 4
        bcf     TRISC, 4, 1      ; SDA = 0
        movlw   5                ; Attend 5 us
        call    Delay_us
        bsf     TRISC, 3, 1      ; SCL = 1 (Relâche l'horloge)
        movlw   5                ; Attend 5 us
        call    Delay_us
        bsf     TRISC, 4, 1      ; SDA = 1 (Relâche les données)
        movlw   5                ; Attend 5 us
        call    Delay_us
        return

; @brief Écrit un octet (dans WREG) sur l'I2C
I2C_Write:
        movwf   i2c_data, 0      ; Sauvegarde la donnée dans l'Access Bank
        movlw   8                ; Initialise le compteur de bits à 8
        movwf   i2c_bit_cnt, 0
I2C_Write_Loop:
        BANKSEL TRISC            ; Sélectionne la banque 4
        btfsc   i2c_data, 7, 0   ; Teste si le bit de poids fort (MSB) est à 1
        bra     I2C_Write_One    ; Si oui, envoie 1
I2C_Write_Zero:
        bcf     TRISC, 4, 1      ; SDA = 0 (Tire la ligne SDA à 0V)
        bra     I2C_Write_Clock  ; Passe au coup d'horloge
I2C_Write_One:
        bsf     TRISC, 4, 1      ; SDA = 1 (Relâche la ligne SDA)
I2C_Write_Clock:
        movlw   5                ; Attend 5 us
        call    Delay_us
        bsf     TRISC, 3, 1      ; SCL = 1 (Coup d'horloge haut)
        movlw   5                ; Attend 5 us
        call    Delay_us
        bcf     TRISC, 3, 1      ; SCL = 0 (Coup d'horloge bas)
        movlw   5                ; Attend 5 us
        call    Delay_us
        rlcf    i2c_data, 1, 0   ; Décale vers la gauche pour tester le bit suivant
        decfsz  i2c_bit_cnt, 1, 0; Décrémente et boucle s'il reste des bits
        bra     I2C_Write_Loop

        ; Lecture de l'acquittement (ACK)
        bsf     TRISC, 4, 1      ; SDA = 1 (Relâche la ligne pour laisser l'esclave répondre)
        movlw   5                ; Attend 5 us
        call    Delay_us
        bsf     TRISC, 3, 1      ; SCL = 1 (Coup d'horloge pour ACK)
        movlw   5                ; Attend 5 us
        call    Delay_us
        bcf     TRISC, 3, 1      ; SCL = 0
        movlw   5                ; Attend 5 us
        call    Delay_us
        return

; ----------------------------------------------------------------------------
; PILOTES LCD HD44780 VIA PCF8574
; ----------------------------------------------------------------------------

; @brief Envoie 4 bits (WREG) avec RS (lcd_rs) et Backlight (backlight_status)
LCD_Send:
        movwf   lcd_data, 0      ; lcd_data = data (bits de poids fort)
        movf    backlight_status, 0, 0 ; Charge backlight dans W
        iorwf   lcd_rs, 0, 0     ; Combine RS et Backlight dans W
        iorwf   lcd_data, 1, 0   ; lcd_data = data | rs | backlight

        call    I2C_Start        ; Démarre la communication I2C
        movlw   0x4E             ; Adresse PCF8574 (0x27) décalée à gauche (0x27 << 1 = 0x4E)
        call    I2C_Write        ; Envoie l'adresse d'écriture

        movf    lcd_data, 0, 0   ; Envoie les données avec EN = 0
        call    I2C_Write
        
        movf    lcd_data, 0, 0   ; Envoie les données avec EN = 1
        iorlw   0x04             ; Active le bit EN (bit 2)
        call    I2C_Write
        movlw   10               ; Pulse de validation EN
        call    Delay_us

        movf    lcd_data, 0, 0   ; Envoie les données avec EN = 0 (Validation du flanc descendant)
        call    I2C_Write
        movlw   50               ; Délai de fin d'instruction
        call    Delay_us

        call    I2C_Stop         ; Arrête la communication I2C
        return

; @brief Envoie une commande 8 bits au LCD (découpée en 2 nibbles)
LCD_Command:
        movwf   lcd_temp, 0      ; Sauvegarde la commande complète
        clrf    lcd_rs, 0        ; Mode commande (RS = 0)
        
        movf    lcd_temp, 0, 0   ; Isole les 4 bits de poids fort
        andlw   0xF0
        call    LCD_Send         ; Envoie les 4 bits de poids fort
        
        swapf   lcd_temp, 0, 0   ; Isole les 4 bits de poids faible
        andlw   0xF0
        call    LCD_Send         ; Envoie les 4 bits de poids faible
        
        movlw   2                ; Pause de 2ms
        call    Delay_ms
        return

; @brief Envoie un caractère ASCII 8 bits au LCD (découpé en 2 nibbles)
LCD_Char:
        movwf   lcd_temp, 0      ; Sauvegarde le caractère
        movlw   1                ; Mode données (RS = 1)
        movwf   lcd_rs, 0
        
        movf    lcd_temp, 0, 0   ; Isole les 4 bits de poids fort
        andlw   0xF0
        call    LCD_Send         ; Envoie les 4 bits de poids fort
        
        swapf   lcd_temp, 0, 0   ; Isole les 4 bits de poids faible
        andlw   0xF0
        call    LCD_Send         ; Envoie les 4 bits de poids faible
        
        movlw   100              ; Pause de 100 us
        call    Delay_us
        return

; @brief Initialise le LCD
LCD_Init:
        movlw   0x08             ; Rétroéclairage ON par défaut
        movwf   backlight_status, 0
        movlw   100              ; Attente stabilisation
        call    Delay_ms
        
        clrf    lcd_rs, 0        ; Initialisation en mode 4 bits
        movlw   0x30
        call    LCD_Send
        movlw   5
        call    Delay_ms
        
        movlw   0x30
        call    LCD_Send
        movlw   1
        call    Delay_ms
        
        movlw   0x30
        call    LCD_Send
        movlw   1
        call    Delay_ms
        
        movlw   0x20             ; Bascule en mode 4-bits
        call    LCD_Send
        movlw   1
        call    Delay_ms
        
        movlw   0x28             ; 2 lignes, police 5x8
        call    LCD_Command
        movlw   0x0C             ; Écran allumé, curseur masqué
        call    LCD_Command
        movlw   0x06             ; Décalage automatique vers la droite
        call    LCD_Command
        movlw   0x01             ; Efface l'écran
        call    LCD_Command
        movlw   5
        call    Delay_ms
        return

; @brief Positionne le curseur
; Entrée : WREG = ligne (1 ou 2), lcd_col = colonne (1-16)
LCD_SetCursor:
        decf    WREG, 0, 0       ; Ligne - 1 (destination WREG, Access Bank)
        bz      LCD_Row1         ; Si 0, ligne 1
LCD_Row2:
        movlw   0xC0             ; Adresse ligne 2 : 0xC0
        bra     LCD_CalcAddr
LCD_Row1:
        movlw   0x80             ; Adresse ligne 1 : 0x80
LCD_CalcAddr:
        addwf   lcd_col, 0, 0    ; Ajoute la colonne (destination WREG, Access Bank)
        addlw   -1               ; Soustrait 1 car 1-indexed
        call    LCD_Command      ; Envoie la commande de positionnement
        return

; @brief Lit une chaîne stockée en ROM et l'affiche sur l'écran LCD
; Entrée : TBLPTR (TBLPTRU, TBLPTRH, TBLPTRL) pré-chargé avec l'adresse de la chaîne
LCD_String_ROM:
LCD_ROM_Loop:
        tblrd*+                  ; Lit la ROM et incrémente le pointeur, place dans TABLAT
        movf    TABLAT, 0, 0     ; Charge le caractère lu dans WREG
        bz      LCD_ROM_Done     ; S'il vaut 0 (fin de chaîne), on quitte
        call    LCD_Char         ; Affiche le caractère
        bra     LCD_ROM_Loop     ; Recommence pour le suivant
LCD_ROM_Done:
        return

        end
