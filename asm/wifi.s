; ============================================================================
; Pilote WiFi pour ESP-01S (wifi.s)
; Implémente la communication UART logicielle et la logique de requêtes.
; ============================================================================
    PROCESSOR 18F47Q84
    #include <xc.inc>

    ; Import des configurations de configs.s et sensor.s
    GLOBAL Wifi_SSID, Wifi_Pass, Web_Host
    GLOBAL Wifi_TX_Pin, Wifi_RX_Pin
    GLOBAL humidity_percent

    ; Import des états effectifs calculés dans main.s pour envoi
    GLOBAL eff_led_green, eff_led_red, eff_pump
    GLOBAL phys_sys_off, phys_manual_pump, phys_info_mode

    ; Export des fonctions globales pour main.s
    GLOBAL Wifi_Init, Wifi_Connect_And_GET
    GLOBAL Delay_ms, Delay_us

    ; Export des variables lues du serveur
    GLOBAL srv_sys_off, srv_manual_pump, srv_info_mode, srv_poll_interval
    GLOBAL buf_temp, buf_day, buf_month, buf_hour, buf_min

    ; ============================================================================
    ; VARIABLES EN ACCESS RAM (Zone mémoire rapide 0x000-0x05F)
    ; ============================================================================
    PSECT udata_acs
wifi_tx_reg:       ds 1         ; Registre de transmission UART
wifi_rx_reg:       ds 1         ; Registre de réception UART
wifi_bit_cnt:      ds 1         ; Compteur de bits
wifi_delay_cnt:    ds 1         ; Compteur de boucle pour les délais de bits
wifi_timeout_l:    ds 1         ; Compteur de timeout octet (octet bas)
wifi_timeout_m:    ds 1         ; Compteur de timeout octet (octet moyen)
wifi_timeout_h:    ds 1         ; Compteur de timeout octet (octet haut)
wifi_temp_val:     ds 1         ; Valeur temporaire pour conversion
wifi_hundreds:     ds 1         ; Chiffre des centaines
wifi_tens:         ds 1         ; Chiffre des dizaines

; Variables d'états reçues du serveur
srv_sys_off:       ds 1         ; État général forcé (0, 1, 2)
srv_manual_pump:   ds 1         ; État pompe forcé (0, 1, 2)
srv_info_mode:     ds 1         ; État écran forcé (0, 1, 2)
srv_poll_interval: ds 1         ; Fréquence de rafraîchissement (secondes)

; Buffers de chaînes de caractères reçus (format ASCII fixe)
buf_temp:          ds 2         ; Température (ex: '2','4')
buf_day:           ds 2         ; Jour (ex: '0','1')
buf_month:         ds 2         ; Mois (ex: '0','7')
buf_hour:          ds 2         ; Heure (ex: '2','1')
buf_min:           ds 2         ; Minute (ex: '0','2')

    ; ============================================================================
    ; CODE DE L'APPLICATION
    ; ============================================================================
    PSECT code

; ----------------------------------------------------------------------------
; INITIALISATION DES BROCHES UART LOGICIELLES
; ----------------------------------------------------------------------------
Wifi_Init:
        ; Désactiver le mode analogique sur les broches RX/TX (Port C)
        BANKSEL ANSELC
        bcf     ANSELC, Wifi_TX_Pin, 1  ; TX en numérique
        bcf     ANSELC, Wifi_RX_Pin, 1  ; RX en numérique
        
        ; Configurer les directions TRIS
        bcf     TRISC, Wifi_TX_Pin, 1   ; TX en sortie
        bsf     TRISC, Wifi_RX_Pin, 1   ; RX en entrée
        
        ; Initialiser la ligne TX à l'état haut (repos)
        BANKSEL LATC
        bsf     LATC, Wifi_TX_Pin, 1
        
        ; Valeurs par défaut pour les états serveur au cas où la première requête échoue
        movlw   2
        movwf   srv_sys_off, 0
        movwf   srv_manual_pump, 0
        movwf   srv_info_mode, 0
        movlw   2
        movwf   srv_poll_interval, 0    ; 2 secondes par défaut
        
        ; Remplir les buffers avec des tirets par défaut
        movlw   '-'
        movwf   buf_temp, 0
        movwf   buf_temp+1, 0
        movwf   buf_day, 0
        movwf   buf_day+1, 0
        movwf   buf_month, 0
        movwf   buf_month+1, 0
        movwf   buf_hour, 0
        movwf   buf_hour+1, 0
        movwf   buf_min, 0
        movwf   buf_min+1, 0
        return

; ----------------------------------------------------------------------------
; DÉLAIS LOGICIELS UART (Calibrés pour 115200 Bauds à 64 MHz)
; ----------------------------------------------------------------------------
; 1 bit = 139 cycles (8.68 us)
Delay_Bit:
        movlw   45                      ; 1 cycle
        movwf   wifi_delay_cnt, 0       ; 1 cycle
Delay_Bit_Loop:
        decfsz  wifi_delay_cnt, 1, 0    ; 1 cycle (2 si saut)
        bra     Delay_Bit_Loop          ; 2 cycles
        return                          ; 2 cycles

; 0.5 bit = 70 cycles (4.34 us)
Delay_HalfBit:
        movlw   22                      ; 1 cycle
        movwf   wifi_delay_cnt, 0       ; 1 cycle
Delay_HalfBit_Loop:
        decfsz  wifi_delay_cnt, 1, 0    ; 1 cycle (2 si saut)
        bra     Delay_HalfBit_Loop      ; 2 cycles
        return                          ; 2 cycles

; ----------------------------------------------------------------------------
; TRANSMISSION UART (Logicielle, LSB en premier)
; ----------------------------------------------------------------------------
UART_Tx_Byte:
        movwf   wifi_tx_reg, 0          ; Sauvegarde la donnée
        
        ; Bit de Start : ligne à 0
        BANKSEL LATC
        bcf     LATC, Wifi_TX_Pin, 1
        call    Delay_Bit
        
        ; Envoi des 8 bits
        movlw   8
        movwf   wifi_bit_cnt, 0
Tx_Loop:
        rrcf    wifi_tx_reg, 1, 0       ; Décale à droite, bit -> Carry
        btfsc   STATUS, 0, 0            ; Teste le Carry
        bra     Tx_One
Tx_Zero:
        BANKSEL LATC
        bcf     LATC, Wifi_TX_Pin, 1
        bra     Tx_Bit_Done
Tx_One:
        BANKSEL LATC
        bsf     LATC, Wifi_TX_Pin, 1
Tx_Bit_Done:
        call    Delay_Bit
        decfsz  wifi_bit_cnt, 1, 0
        bra     Tx_Loop
        
        ; Bit de Stop : ligne à 1
        BANKSEL LATC
        bsf     LATC, Wifi_TX_Pin, 1
        call    Delay_Bit
        call    Delay_Bit               ; Temps d'arrêt supplémentaire
        return

; ----------------------------------------------------------------------------
; RÉCEPTION UART AVEC TIMEOUT (Logicielle)
; ----------------------------------------------------------------------------
; Sortie : WREG = octet reçu, Carry = 1 si timeout, Carry = 0 si succès.
UART_Rx_Byte_Timeout:
        clrf    wifi_rx_reg, 0
Rx_Wait_Start:
        BANKSEL PORTC
        btfss   PORTC, Wifi_RX_Pin, 1   ; Détection du flanc descendant (Start)
        bra     Rx_Start_Detected
        
        ; Décrémentation du compteur 24 bits
        decfsz  wifi_timeout_l, 1, 0
        bra     Rx_Wait_Start
        decfsz  wifi_timeout_m, 1, 0
        bra     Rx_Wait_Start
        decfsz  wifi_timeout_h, 1, 0
        bra     Rx_Wait_Start
        
        ; Timeout expiré
        bsf     STATUS, 0, 0            ; Met le Carry à 1
        return

Rx_Start_Detected:
        call    Delay_HalfBit           ; Se place au milieu du bit de start
        BANKSEL PORTC
        btfsc   PORTC, Wifi_RX_Pin, 1   ; Vérifie s'il est toujours bas
        bra     Rx_Wait_Start           ; Faux départ
        
        movlw   8
        movwf   wifi_bit_cnt, 0
Rx_Loop:
        call    Delay_Bit               ; Attend le milieu du bit suivant
        
        bcf     STATUS, 0, 0            ; Carry = 0
        BANKSEL PORTC
        btfsc   PORTC, Wifi_RX_Pin, 1   ; Échantillonne la broche
        bsf     STATUS, 0, 0            ; Carry = 1 si la broche est haute
        
        rrcf    wifi_rx_reg, 1, 0       ; Injecte le bit par la gauche
        decfsz  wifi_bit_cnt, 1, 0
        bra     Rx_Loop
        
        call    Delay_Bit               ; Attend le bit de stop
        movf    wifi_rx_reg, 0, 0       ; Place la valeur dans WREG
        bcf     STATUS, 0, 0            ; Clear Carry (succès)
        return

; ----------------------------------------------------------------------------
; ENVOI D'UNE CHAÎNE DE CARACTÈRES DEPUIS LA ROM
; ----------------------------------------------------------------------------
UART_Send_String_ROM:
        tblrd*+                         ; Lecture de l'octet ROM pointé par TBLPTR
        movf    TABLAT, 0, 0            ; Place l'octet dans WREG
        bz      UART_Send_String_End    ; Si 0, fin de chaîne
        call    UART_Tx_Byte            ; Transmet le caractère
        bra     UART_Send_String_ROM
UART_Send_String_End:
        return

; ----------------------------------------------------------------------------
; ATTENTE D'UN SIGNAL OK (Timeout personnalisable)
; ----------------------------------------------------------------------------
UART_Wait_OK_Timeout:
        movwf   wifi_timeout_h, 0
        clrf    wifi_timeout_m, 0
        clrf    wifi_timeout_l, 0
Wait_O:
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0            ; Si timeout, retourne avec Carry = 1
        return
        xorlw   'O'
        bnz     Wait_O
Wait_K:
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        xorlw   'K'
        bz      OK_Found
        xorlw   'K' ^ 'O'               ; Est-ce un autre 'O' ?
        bz      Wait_K
        bra     Wait_O
OK_Found:
        bcf     STATUS, 0, 0            ; Succès
        return

; Version longue attente (~15 secondes) pour la connexion WiFi (CWJAP)
UART_Wait_OK_Long:
        movlw   0xE4
        movwf   wifi_timeout_h, 0
        movlw   0xE1
        movwf   wifi_timeout_m, 0
        movlw   0xC0
        movwf   wifi_timeout_l, 0
        bra     Wait_O

; ----------------------------------------------------------------------------
; ATTENTE DE LA PROMPT '>'
; ----------------------------------------------------------------------------
UART_Wait_Prompt:
        movlw   0xC0                    ; ~5 secondes
        movwf   wifi_timeout_h, 0
        clrf    wifi_timeout_m, 0
        clrf    wifi_timeout_l, 0
Wait_Prompt_Loop:
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        xorlw   '>'
        bnz     Wait_Prompt_Loop
        bcf     STATUS, 0, 0
        return

; ----------------------------------------------------------------------------
; ATTENTE DU PAYLOAD DU SERVEUR ("C:")
; ----------------------------------------------------------------------------
UART_Wait_Payload:
        movlw   0xC0                    ; ~5 secondes
        movwf   wifi_timeout_h, 0
        clrf    wifi_timeout_m, 0
        clrf    wifi_timeout_l, 0
Wait_C:
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        xorlw   'C'
        bnz     Wait_C
Wait_Colon:
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        xorlw   ':'
        bz      Payload_Found
        xorlw   ':' ^ 'C'               ; C'était un 'C' ?
        bz      Wait_Colon
        bra     Wait_C
Payload_Found:
        bcf     STATUS, 0, 0
        return

; ----------------------------------------------------------------------------
; UTILS : CONVERSION ET ENVOI DE WREG EN DÉCIMAL ASCII
; ----------------------------------------------------------------------------
Send_WREG_Decimal:
        movwf   wifi_temp_val, 0
        clrf    wifi_hundreds, 0
        clrf    wifi_tens, 0
        
Convert_Hundreds:
        movlw   100
        subwf   wifi_temp_val, 0, 0
        bnc     Convert_Tens
        movwf   wifi_temp_val, 0
        incf    wifi_hundreds, 1, 0
        bra     Convert_Hundreds

Convert_Tens:
        movlw   10
        subwf   wifi_temp_val, 0, 0
        bnc     Convert_Ones
        movwf   wifi_temp_val, 0
        incf    wifi_tens, 1, 0
        bra     Convert_Tens

Convert_Ones:
        movf    wifi_hundreds, 0, 0
        bz      Check_Tens
        addlw   '0'
        call    UART_Tx_Byte
        bra     Send_Tens

Check_Tens:
        movf    wifi_tens, 0, 0
        bz      Send_Ones
Send_Tens:
        movf    wifi_tens, 0, 0
        addlw   '0'
        call    UART_Tx_Byte

Send_Ones:
        movf    wifi_temp_val, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        return

; ----------------------------------------------------------------------------
; SEQUENCE DE CONNEXION WIFI ET ENVOI DE LA REQUÊTE
; ----------------------------------------------------------------------------
; Sortie : Carry = 0 si succès, Carry = 1 si échec.
Wifi_Connect_And_GET:
        ; --- Etape 1 : Ping AT ---
        movlw   low(Str_AT)
        movwf   TBLPTRL, 0
        movlw   high(Str_AT)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_AT)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   0xC0                    ; ~5 secondes
        call    UART_Wait_OK_Timeout
        btfsc   STATUS, 0, 0
        return                          ; Retourne avec Carry = 1

        ; --- Etape 2 : Mode Station ---
        movlw   low(Str_CWMODE)
        movwf   TBLPTRL, 0
        movlw   high(Str_CWMODE)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CWMODE)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   0xC0
        call    UART_Wait_OK_Timeout
        btfsc   STATUS, 0, 0
        return

        ; --- Etape 3 : Connexion WiFi ---
        movlw   low(Str_CWJAP_Start)
        movwf   TBLPTRL, 0
        movlw   high(Str_CWJAP_Start)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CWJAP_Start)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Wifi_SSID)
        movwf   TBLPTRL, 0
        movlw   high(Wifi_SSID)
        movwf   TBLPTRH, 0
        movlw   low highword(Wifi_SSID)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Str_CWJAP_Mid)
        movwf   TBLPTRL, 0
        movlw   high(Str_CWJAP_Mid)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CWJAP_Mid)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Wifi_Pass)
        movwf   TBLPTRL, 0
        movlw   high(Wifi_Pass)
        movwf   TBLPTRH, 0
        movlw   low highword(Wifi_Pass)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Str_CWJAP_End)
        movwf   TBLPTRL, 0
        movlw   high(Str_CWJAP_End)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CWJAP_End)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        call    UART_Wait_OK_Long
        btfsc   STATUS, 0, 0
        return

        ; --- Etape 4 : Connexion TCP ---
        movlw   low(Str_CIPSTART_Start)
        movwf   TBLPTRL, 0
        movlw   high(Str_CIPSTART_Start)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CIPSTART_Start)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Web_Host)
        movwf   TBLPTRL, 0
        movlw   high(Web_Host)
        movwf   TBLPTRH, 0
        movlw   low highword(Web_Host)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   low(Str_CIPSTART_End)
        movwf   TBLPTRL, 0
        movlw   high(Str_CIPSTART_End)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CIPSTART_End)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movlw   0xC0
        call    UART_Wait_OK_Timeout
        btfsc   STATUS, 0, 0
        return

        ; --- Etape 5 : Préparation de l'envoi de la requête ---
        movlw   low(Str_CIPSEND_Start)
        movwf   TBLPTRL, 0
        movlw   high(Str_CIPSEND_Start)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CIPSEND_Start)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; Déterminer la longueur de la requête HTTP (longueur de base + 18 octets pour pb0, pb1, pb2)
        movf    humidity_percent, 0, 0
        movwf   wifi_temp_val, 0
        movlw   10
        subwf   wifi_temp_val, 0, 0
        bnc     Len_Is_149
        movlw   100
        subwf   wifi_temp_val, 0, 0
        bnc     Len_Is_150
Len_Is_151:
        movlw   151
        bra     Send_Len
Len_Is_150:
        movlw   150
        bra     Send_Len
Len_Is_149:
        movlw   149
Send_Len:
        call    Send_WREG_Decimal
        
        movlw   low(Str_CRLF)
        movwf   TBLPTRL, 0
        movlw   high(Str_CRLF)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CRLF)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        call    UART_Wait_Prompt
        btfsc   STATUS, 0, 0
        return

        ; --- Etape 6 : Envoi des pièces de la requête HTTP ---
        ; Part 1: GET /api/update?hum=
        movlw   low(Str_Req_Part1)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part1)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part1)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; Valeur de l'humidité
        movf    humidity_percent, 0, 0
        call    Send_WREG_Decimal
        
        ; Part 2: &led_green=
        movlw   low(Str_Req_Part2)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part2)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part2)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; Valeur led_green
        movf    eff_led_green, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Part 3: &led_red=
        movlw   low(Str_Req_Part3)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part3)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part3)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; Valeur led_red
        movf    eff_led_red, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Part 4: &pump=
        movlw   low(Str_Req_Part4)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part4)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part4)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; Valeur pump
        movf    eff_pump, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Envoyé pb0
        movlw   low(Str_Req_Part_PB0)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part_PB0)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part_PB0)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movf    phys_sys_off, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Envoyé pb1
        movlw   low(Str_Req_Part_PB1)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part_PB1)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part_PB1)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movf    phys_manual_pump, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Envoyé pb2
        movlw   low(Str_Req_Part_PB2)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part_PB2)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part_PB2)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        movf    phys_info_mode, 0, 0
        addlw   '0'
        call    UART_Tx_Byte
        
        ; Part 5: HTTP/1.1\r\nHost:...\r\nConnection: close\r\n\r\n
        movlw   low(Str_Req_Part5)
        movwf   TBLPTRL, 0
        movlw   high(Str_Req_Part5)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_Req_Part5)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        ; --- Etape 7 : Attente et Lecture du Payload ---
        call    UART_Wait_Payload
        btfsc   STATUS, 0, 0
        return                          ; Retourne avec Carry = 1 (Échec)
        
        ; Format attendu : s,m,i,pp|T:tt|D:DD/MM|H:HH:MM
        ; 7.1 Lire sys_off
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        addlw   -0x30
        movwf   srv_sys_off, 0
        
        ; Sauter ','
        call    UART_Rx_Byte_Timeout
        
        ; 7.2 Lire manual_pump
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        addlw   -0x30
        movwf   srv_manual_pump, 0
        
        ; Sauter ','
        call    UART_Rx_Byte_Timeout
        
        ; 7.3 Lire info_mode
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        addlw   -0x30
        movwf   srv_info_mode, 0
        
        ; Sauter ','
        call    UART_Rx_Byte_Timeout
        
        ; 7.4 Lire poll interval digit 1
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        addlw   -0x30
        movwf   wifi_temp_val, 0
        movlw   10
        mulwf   wifi_temp_val, 0
        movf    PRODL, 0, 0
        movwf   srv_poll_interval, 0
        
        ; Lire poll interval digit 2
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        addlw   -0x30
        addwf   srv_poll_interval, 1, 0
        
        ; Sauter '|', 'T', ':'
        call    UART_Rx_Byte_Timeout ; |
        call    UART_Rx_Byte_Timeout ; T
        call    UART_Rx_Byte_Timeout ; :
        
        ; 7.5 Lire Temp (2 octets)
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_temp, 0
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_temp+1, 0
        
        ; Sauter '|', 'D', ':'
        call    UART_Rx_Byte_Timeout ; |
        call    UART_Rx_Byte_Timeout ; D
        call    UART_Rx_Byte_Timeout ; :
        
        ; 7.6 Lire Date: Day (2 octets), '/' (1), Month (2)
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_day, 0
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_day+1, 0
        
        call    UART_Rx_Byte_Timeout ; Skip '/'
        
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_month, 0
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_month+1, 0
        
        ; Sauter '|', 'H', ':'
        call    UART_Rx_Byte_Timeout ; |
        call    UART_Rx_Byte_Timeout ; H
        call    UART_Rx_Byte_Timeout ; :
        
        ; 7.7 Lire Time: Hour (2 octets), ':' (1), Min (2)
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_hour, 0
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_hour+1, 0
        
        call    UART_Rx_Byte_Timeout ; Skip ':'
        
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_min, 0
        call    UART_Rx_Byte_Timeout
        btfsc   STATUS, 0, 0
        return
        movwf   buf_min+1, 0
        
        ; Fermeture propre de la connexion TCP
        movlw   low(Str_CIPCLOSE)
        movwf   TBLPTRL, 0
        movlw   high(Str_CIPCLOSE)
        movwf   TBLPTRH, 0
        movlw   low highword(Str_CIPCLOSE)
        movwf   TBLPTRU, 0
        call    UART_Send_String_ROM
        
        bcf     STATUS, 0, 0            ; Succès
        return

; ----------------------------------------------------------------------------
; COMMANDES BRUTES AT (Mémoire ROM)
; ----------------------------------------------------------------------------
Str_AT:
    db 'A','T',13,10,0
Str_CWMODE:
    db 'A','T','+','C','W','M','O','D','E','=','1',13,10,0
Str_CWJAP_Start:
    db 'A','T','+','C','W','J','A','P','=','"',0
Str_CWJAP_Mid:
    db '"',',','"',0
Str_CWJAP_End:
    db '"',13,10,0
Str_CIPSTART_Start:
    db 'A','T','+','C','I','P','S','T','A','R','T','=','"','T','C','P','"',',','"',0
Str_CIPSTART_End:
    db '"',',','8','0',13,10,0
Str_CIPSEND_Start:
    db 'A','T','+','C','I','P','S','E','N','D','=',0
Str_CRLF:
    db 13,10,0
Str_CIPCLOSE:
    db 'A','T','+','C','I','P','C','L','O','S','E',13,10,0

; Morceaux de la requête HTTP
Str_Req_Part1:
    db 'G','E','T',' ','/','a','p','i','/','u','p','d','a','t','e','?','h','u','m','=',0
Str_Req_Part2:
    db '&','l','e','d','_','g','r','e','e','n','=',0
Str_Req_Part3:
    db '&','l','e','d','_','r','e','d','=',0
Str_Req_Part4:
    db '&','p','u','m','p','=',0
Str_Req_Part_PB0:
    db '&','p','b','0','=',0
Str_Req_Part_PB1:
    db '&','p','b','1','=',0
Str_Req_Part_PB2:
    db '&','p','b','2','=',0
Str_Req_Part5:
    db ' ','H','T','T','P','/','1','.','1',13,10
    db 'H','o','s','t',':',' ','e','m','b','e','d','d','e','d','-','s','y','s','t','e','m','-','p','r','o','j','e','c','t','.','o','n','r','e','n','d','e','r','.','c','o','m',13,10
    db 'C','o','n','n','e','c','t','i','o','n',':',' ','c','l','o','s','e',13,10,13,10,0
