; ============================================================================
; Fichier de Configuration Globale (configs.s)
; Contient les paramètres du réseau WiFi, de l'hôte et des requêtes.
; ============================================================================
    PROCESSOR 18F47Q84
    #include <xc.inc>

    ; Déclarations des constantes et chaînes globales
    GLOBAL Wifi_SSID, Wifi_Pass, Web_Host
    GLOBAL Wifi_TX_Pin, Wifi_RX_Pin

    ; Définition des broches UART logicielles
    ; Broches par défaut : RC6 (TX) et RC7 (RX)
Wifi_TX_Pin EQU 6
Wifi_RX_Pin EQU 7

    PSECT code

; Nom du réseau WiFi (SSID)
Wifi_SSID:
    db 'R','e','d','m','i',' ','N','o','t','e',' ','1','3',' ','P','r','o','+',' ','5','G',0

; Mot de passe du réseau WiFi
Wifi_Pass:
    db 'p','e','r','t','i','n','e','n','t','2','3',0

; Hôte pour la connexion TCP (embedded-system-project.onrender.com)
Web_Host:
    db 'e','m','b','e','d','d','e','d','-','s','y','s','t','e','m','-','p','r','o','j','e','c','t','.','o','n','r','e','n','d','e','r','.','c','o','m',0
