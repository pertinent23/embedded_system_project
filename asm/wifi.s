    PROCESSOR   18F47Q84
    #include    <xc.inc>

    GLOBAL WIFI_Init, WIFI_Task
    GLOBAL wifi_sys_off, wifi_manual_pump, wifi_info_mode
    GLOBAL wifi_network_ok

    EXTERN humidity_percent, Delay_ms
    EXTERN math_arg1L, math_arg1H

; ============================================================================
; VARIABLES DE CONFIGURATION WIFI (Modifiables en ROM)
; ============================================================================
    PSECT constData, class=CONST, reloc=2
WIFI_SSID:      DB "Mon_Reseau_WiFi", 0
WIFI_PASS:      DB "MotDePasse123", 0
WIFI_SERVER:    DB "192.168.1.100", 0
WIFI_PORT:      DB "80", 0

; Commandes AT
AT_RESET:       DB "AT+RST\r\n", 0
AT_CWMODE:      DB "AT+CWMODE=1\r\n", 0
AT_CWJAP_PRE:   DB "AT+CWJAP=\"", 0
AT_CWJAP_MID:   DB "\",\"", 0
AT_CWJAP_POST:  DB "\"\r\n", 0
AT_CIPSTART_1:  DB "AT+CIPSTART=\"TCP\",\"", 0
AT_CIPSTART_2:  DB "\",80\r\n", 0
AT_CIPSEND:     DB "AT+CIPSEND=25\r\n", 0 ; Taille fixe pour l'exemple
HTTP_GET_PRE:   DB "GET /api/update?hum=", 0
HTTP_GET_POST:  DB " HTTP/1.1\r\n\r\n", 0
STR_CMD:        DB "CMD:", 0

; ============================================================================
; VARIABLES RAM (ÉTATS ET BUFFERS)
; ============================================================================
    UDATA
wifi_state:         RES 1   ; Machine à états (0=Init, 1=WaitAP, 2=TCP, 3=Req, 4=Parse)
wifi_network_ok:    RES 1   
wifi_delay_cnt:     RES 1   ; Compteur d'attente pour donner le temps à l'ESP de répondre

; Priorités (0=Actif, 1=Inactif, 2=Bouton Physique)
wifi_sys_off:       RES 1   
wifi_manual_pump:   RES 1   
wifi_info_mode:     RES 1   

; Buffer circulaire de réception UART
RX_BUFFER_SIZE EQU 32
rx_buffer:          RES RX_BUFFER_SIZE
rx_head:            RES 1
rx_tail:            RES 1
parse_state:        RES 1

; ============================================================================
; MACROS
; ============================================================================
PRINT_UART_ROM MACRO string_label
    MOVLW low highword(string_label)
    MOVWF TBLPTRU
    MOVLW high(string_label)
    MOVWF TBLPTRH
    MOVLW low(string_label)
    MOVWF TBLPTRL
    CALL UART_String_ROM
    ENDM

    PSECT text, class=CODE, reloc=2

; ============================================================================
; INITIALISATION WIFI ET UART
; ============================================================================
WIFI_Init:
    ; Variables à 2 (Ignoré / Mode Physique)
    MOVLW 2
    MOVWF wifi_sys_off
    MOVWF wifi_manual_pump
    MOVWF wifi_info_mode
    CLRF wifi_state
    CLRF wifi_network_ok
    CLRF rx_head
    CLRF rx_tail

    ; --- Configuration matérielle UART1 (9600 bps à 64 MHz) ---
    ; RC6 = TX, RC7 = RX
    BCF TRISC, 6    ; TX en sortie
    BSF TRISC, 7    ; RX en entrée
    
    ; Setup UART registers (Spécifique au PIC18F47Q84)
    ; SYNC=0, BRGH=1, BRG16=1 -> SPBRG = 1666 pour 9600 bps
    BCF TX1STA, 4   ; SYNC = 0
    BSF TX1STA, 2   ; BRGH = 1
    BSF BAUD1CON, 3 ; BRG16 = 1
    
    MOVLW low(1666)
    MOVWF SP1BRGL
    MOVLW high(1666)
    MOVWF SP1BRGH
    
    BSF RC1STA, 7   ; SPEN = 1 (Enable Serial Port)
    BSF TX1STA, 5   ; TXEN = 1 (Enable Transmitter)
    BSF RC1STA, 4   ; CREN = 1 (Enable Receiver)
    RETURN

; ============================================================================
; TÂCHE WIFI NON-BLOQUANTE (Appelée cycliquement)
; ============================================================================
WIFI_Task:
    ; Traitement du buffer de réception entrant
    CALL Process_RX_Buffer

    ; Délai non-bloquant inter-états
    MOVF wifi_delay_cnt, W
    BZ Check_State
    DECF wifi_delay_cnt, F
    RETURN

Check_State:
    MOVF wifi_state, W
    BZ State_Reset
    DECF WREG, W
    BZ State_CWMODE
    DECF WREG, W
    BZ State_ConnectAP
    DECF WREG, W
    BZ State_ConnectTCP
    DECF WREG, W
    BZ State_SendReqSize
    DECF WREG, W
    BZ State_SendPayload
    DECF WREG, W
    BZ State_WaitReply
    RETURN

State_Reset:
    PRINT_UART_ROM AT_RESET
    MOVLW 5
    MOVWF wifi_delay_cnt ; Pause de 5 cycles pour laisser rebooter
    INCF wifi_state, F
    RETURN

State_CWMODE:
    PRINT_UART_ROM AT_CWMODE
    MOVLW 1
    MOVWF wifi_delay_cnt
    INCF wifi_state, F
    RETURN

State_ConnectAP:
    ; Concaténation de AT+CWJAP="SSID","PASS"
    PRINT_UART_ROM AT_CWJAP_PRE
    PRINT_UART_ROM WIFI_SSID
    PRINT_UART_ROM AT_CWJAP_MID
    PRINT_UART_ROM WIFI_PASS
    PRINT_UART_ROM AT_CWJAP_POST
    MOVLW 10 ; La connexion WiFi est longue (10 secondes)
    MOVWF wifi_delay_cnt
    INCF wifi_state, F
    RETURN

State_ConnectTCP:
    PRINT_UART_ROM AT_CIPSTART_1
    PRINT_UART_ROM WIFI_SERVER
    PRINT_UART_ROM AT_CIPSTART_2
    MOVLW 3 ; Connexion TCP 3 secondes
    MOVWF wifi_delay_cnt
    INCF wifi_state, F
    RETURN

State_SendReqSize:
    PRINT_UART_ROM AT_CIPSEND
    MOVLW 1 ; Attendre 1 sec le prompt '>'
    MOVWF wifi_delay_cnt
    INCF wifi_state, F
    RETURN

State_SendPayload:
    ; Envoi de "GET /?hum=XX HTTP/1.1"
    PRINT_UART_ROM HTTP_GET_PRE
    
    ; Extraction de l'humidité en ASCII
    MOVF humidity_percent, W
    CALL UART_Print_2_Digits
    
    PRINT_UART_ROM HTTP_GET_POST
    MOVLW 2 ; Attente de la réponse du serveur (2 secondes)
    MOVWF wifi_delay_cnt
    INCF wifi_state, F
    CLRF parse_state ; Prépare le parseur à chercher la réponse
    RETURN

State_WaitReply:
    ; L'état reste ici, la réponse est traitée par Process_RX_Buffer
    ; Après avoir analysé, on repasse au TCP pour la requête suivante
    MOVLW 3
    MOVWF wifi_state
    RETURN

; ============================================================================
; GESTION UART (Bas Niveau)
; ============================================================================

; Envoi d'un octet (bloquant jusqu'à dispo du buffer d'émission)
UART_Write:
    BTFSS PIR3, 4   ; TX1IF ? (Le registre exact dépend de l'assignation PIRx du Q84)
    BRA UART_Write  ; Attend que le buffer soit vide
    MOVWF TX1REG
    RETURN

; Envoi d'une chaîne ROM vers UART
UART_String_ROM:
Loop_UART_ROM:
    TBLRD*+
    MOVF TABLAT, W
    BZ End_UART_ROM
    CALL UART_Write
    BRA Loop_UART_ROM
End_UART_ROM:
    RETURN

; Convertit 0-99 en ASCII et envoie sur UART
UART_Print_2_Digits:
    CLRF math_arg1L
U2_Loop:
    MOVLW 10
    SUBWF WREG, W
    BN U2_Got_Tens
    MOVWF WREG
    INCF math_arg1L, F
    BRA U2_Loop
U2_Got_Tens:
    MOVWF math_arg1H
    MOVF math_arg1L, W
    ADDLW 0x30
    CALL UART_Write
    MOVF math_arg1H, W
    ADDLW 0x30
    CALL UART_Write
    RETURN

; ============================================================================
; RÉCEPTION UART ET ANALYSEUR DE TEXTE (PARSER)
; ============================================================================

Process_RX_Buffer:
    ; Vérifie s'il y a un octet entrant dans l'UART (Non-bloquant)
    BTFSS PIR3, 5   ; RC1IF ?
    RETURN          ; Rien reçu, on quitte
    
    MOVF RC1REG, W  ; Lit l'octet reçu
    ; On peut le stocker dans un buffer circulaire si besoin.
    ; Mais ici, nous allons l'analyser "à la volée" (State Machine Parser)
    ; pour détecter "CMD:X,Y,Z" où X,Y,Z = 0, 1 ou 2.

    ; Le parse_state garde en mémoire la lettre attendue.
    MOVF parse_state, W
    BZ Wait_C
    DECF WREG, W
    BZ Wait_M
    DECF WREG, W
    BZ Wait_D
    DECF WREG, W
    BZ Wait_Colon
    DECF WREG, W
    BZ Get_Sys
    DECF WREG, W
    BZ Get_Pump
    DECF WREG, W
    BZ Get_Info
    CLRF parse_state
    RETURN

Wait_C:
    MOVLW 'C'
    XORWF RC1REG, W
    BNZ Reset_Parser
    INCF parse_state, F
    RETURN
Wait_M:
    MOVLW 'M'
    XORWF RC1REG, W
    BNZ Reset_Parser
    INCF parse_state, F
    RETURN
Wait_D:
    MOVLW 'D'
    XORWF RC1REG, W
    BNZ Reset_Parser
    INCF parse_state, F
    RETURN
Wait_Colon:
    MOVLW ':'
    XORWF RC1REG, W
    BNZ Reset_Parser
    INCF parse_state, F
    RETURN

Get_Sys:
    ; Lecture du sys_off (Ex: '0', '1', '2')
    MOVF RC1REG, W
    SUBLW 0x30 ; Convertit ASCII en entier
    NEGF WREG
    MOVWF wifi_sys_off
    ; On ignore la virgule pour simplifier (on l'écrase sur le prochain char)
    INCF parse_state, F
    RETURN

Get_Pump:
    ; Ce char est une virgule, on l'ignore. Le suivant sera la valeur.
    MOVLW ','
    XORWF RC1REG, W
    BZ Skip_Pump_Comma
    
    MOVF RC1REG, W
    SUBLW 0x30
    NEGF WREG
    MOVWF wifi_manual_pump
    INCF parse_state, F
    RETURN
Skip_Pump_Comma:
    RETURN

Get_Info:
    MOVLW ','
    XORWF RC1REG, W
    BZ Skip_Info_Comma
    
    MOVF RC1REG, W
    SUBLW 0x30
    NEGF WREG
    MOVWF wifi_info_mode
    ; Fin du parsing, on réinitialise
    CLRF parse_state
    BSF wifi_network_ok, 0 ; Marque le réseau comme opérationnel
    RETURN
Skip_Info_Comma:
    RETURN

Reset_Parser:
    CLRF parse_state
    RETURN

    END
