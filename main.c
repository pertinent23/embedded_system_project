#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>      // Requis pour utiliser la fonction sprintf() (formatage de texte)

// ============================================================================
// CONFIGURATION DE L'OSCILLATEUR ET DU PIC (Pragmas)
// ============================================================================
// Les #pragma config sont des instructions lues par le programmateur (PICkit) 
// avant même que le code ne démarre, pour câbler le cerveau du composant.
#pragma config FEXTOSC = OFF        // Désactive l'attente d'un quartz externe (composant électronique de chronométrage)
#pragma config RSTOSC = HFINTOSC_64 // Active l'oscillateur interne haute fréquence réglé à 64 MHz (très rapide)
#pragma config WDTE = OFF           // Désactive le "Chien de garde" (qui fait redémarrer le PIC s'il plante) pour faciliter le développement
#pragma config LVP = ON             // Active la programmation basse tension (requis par les programmateurs modernes comme SNAP/PICkit4)

// ============================================================================
// DÉFINITIONS GLOBALES ET CONSTANTES
// ============================================================================
// _XTAL_FREQ est une macro exigée par le compilateur XC8 pour savoir comment 
// calculer le temps quand on appelle la fonction de pause __delay_ms()
#define _XTAL_FREQ 64000000         // Doit correspondre exactement à HFINTOSC_64 (64 millions de cycles/seconde)

// --- Adresses matérielles ---
#define I2C_LCD_ADDR 0x27           // Adresse "postale" réseau I2C standard des modules LCD (parfois 0x3F selon le fabricant)

// --- Alias des broches matérielles ---
// Utiliser LATx (Latch) au lieu de PORTx pour écrire (sorties) évite le bug classique du "Read-Modify-Write"
#define HYGRO_POWER_PIN     LATAbits.LATA1
#define RELAY_PUMP_PIN      LATDbits.LATD0
#define LED_GREEN_PIN       LATDbits.LATD1
#define LED_RED_PIN         LATDbits.LATD2

// Utiliser PORTx pour lire (entrées) l'état réel de la broche physique
#define SW_SYSTEM_ON_OFF    PORTBbits.RB0
#define SW_FORCE_PUMP       PORTBbits.RB1
#define SW_INFO_MODE        PORTBbits.RB2

// --- Alias pour le bus I2C Logiciel (Bit-Banging sur RC3 et RC4) ---
// En I2C, on ne met jamais les broches à 5V (niveau haut forcé).
// Soit on les relie à la masse (0V), soit on les laisse "flotter" (Input) et des résistances externes les tirent à 5V.
// TRIS gère la direction (1 = Input/Flottant, 0 = Output).
#define I2C_SCL_DIR         TRISCbits.TRISC3
#define I2C_SDA_DIR         TRISCbits.TRISC4
#define I2C_SCL_LAT         LATCbits.LATC3
#define I2C_SDA_LAT         LATCbits.LATC4

// --- Constantes de Calibration du Capteur d'Humidité ---
const uint16_t ADC_SEC_MAX = 800;   // Valeur lue quand la terre est sèche (la résistance de la terre est forte)
const uint16_t ADC_HUMIDE = 400;    // Valeur lue quand la terre est humide (l'eau conduit l'électricité, la résistance baisse)

// ============================================================================
// VARIABLES GLOBALES
// ============================================================================
uint16_t current_adc_value = 0;     // Stocke le nombre entre 0 et 4095 issu du convertisseur
uint8_t current_humidity_percent = 0; // Stocke la valeur finale de 0 à 100%
bool is_pump_active = false;        // bool est un type Vrai/Faux (True/False)
char lcd_buffer[17];                // Tableau de 17 cases (16 caractères max par ligne + le caractère '\0' de fin de texte)

// ============================================================================
// PROTOTYPES DES FONCTIONS
// ============================================================================
// C'est le "sommaire" du programme. Il dit au compilateur que ces fonctions 
// existent et qu'on les détaillera plus bas dans le fichier.
void System_Initialize(void);
uint16_t ADC_Read_Humidity(void);
void I2C_Init(void);
void I2C_Start(void);
void I2C_Stop(void);
void I2C_Write(uint8_t data);
void LCD_Init(uint8_t i2c_addr);
void LCD_Command(uint8_t i2c_addr, uint8_t cmd);
void LCD_Char(uint8_t i2c_addr, char data);
void LCD_String(uint8_t i2c_addr, const char *str);
void LCD_SetCursor(uint8_t i2c_addr, uint8_t row, uint8_t col);
void LCD_Clear(uint8_t i2c_addr);

// ============================================================================
// FONCTION PRINCIPALE
// ============================================================================
void main(void) {
    // 1. Appel de la fonction pour configurer toutes les broches du microcontrôleur
    System_Initialize();
    
    // 2. Initialisation des bus de communication et de l'écran
    I2C_Init();
    __delay_ms(100);             // Laisse le temps au petit processeur de l'écran LCD de démarrer
    LCD_Init(I2C_LCD_ADDR);
    
    // Affichage d'un message d'accueil
    LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
    LCD_String(I2C_LCD_ADDR, "Systeme Demarre ");
    __delay_ms(2000);            // Pause de 2 secondes
    LCD_Clear(I2C_LCD_ADDR);     // Efface l'écran

    // 3. Boucle infinie (Le programme ne sortira jamais d'ici)
    while (1) {
        
        // --- GESTION INTERRUPTEUR PRINCIPAL (Marche/Arrêt) ---
        // L'interrupteur est relié à la broche et à la masse. S'il est ouvert,
        // la résistance de tirage (Pull-up) interne maintient la broche à 1 logique (5V).
        // Donc si == 1, on veut arrêter le système.
        if (SW_SYSTEM_ON_OFF == 1) { 
            RELAY_PUMP_PIN = 0;     // Coupe le courant vers la pompe
            LED_GREEN_PIN = 0;      // Eteint le voyant "OK"
            LED_RED_PIN = 1;        // Allume le voyant "Veille"
            
            LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
            LCD_String(I2C_LCD_ADDR, " SYSTEME ETEINT ");
            LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
            LCD_String(I2C_LCD_ADDR, "  (Mode Veille) ");
            
            __delay_ms(500);
            continue; // L'instruction continue annule le reste du code en dessous et force la boucle while(1) à recommencer au début.
        }
        
        // Si on arrive ici, c'est que le système est allumé (SW_SYSTEM_ON_OFF == 0)
        LED_GREEN_PIN = 1;
        LED_RED_PIN = 0;

        // --- LECTURE DU CAPTEUR ---
        // On récupère une valeur brute (ex: 600)
        current_adc_value = ADC_Read_Humidity();
        
        // Sécurisation : on borne la valeur lue pour éviter les bugs de calcul.
        // Si on lit 850 (plus sec que sec), on le bloque à 800.
        if(current_adc_value > ADC_SEC_MAX) current_adc_value = ADC_SEC_MAX;
        if(current_adc_value < ADC_HUMIDE) current_adc_value = ADC_HUMIDE;
        
        // Formule mathématique (Produit en croix inversé)
        // (current_adc_value - ADC_HUMIDE) ramène l'échelle à 0.
        // On multiplie par 100 PUIS on divise (pour ne pas perdre les décimales en calcul entier).
        // On fait 100 - (...) car la résistance BAISSE quand l'humidité AUGMENTE (logique inversée).
        current_humidity_percent = 100 - ((current_adc_value - ADC_HUMIDE) * 100) / (ADC_SEC_MAX - ADC_HUMIDE);

        // --- GESTION DU RELAIS (Pompe) ---
        // Interrupteur 2 : S'il est fermé (0V), on ignore les capteurs et on allume
        if (SW_FORCE_PUMP == 0) {
            is_pump_active = true;
        } 
        else {
            // Logique automatique avec le capteur
            if (current_adc_value >= ADC_SEC_MAX) {
                is_pump_active = true;  // Il fait trop sec -> Pompe ON
            } else if (current_adc_value <= ADC_HUMIDE) {
                is_pump_active = false; // C'est inondé -> Pompe OFF
            }
            // Note: Si la valeur est entre les deux (ex: 600), l'état ne change pas. 
            // C'est ce qu'on appelle "l'hystérésis", ça évite que la pompe clignote on/off/on/off très vite.
        }
        
        // Applique physiquement la tension sur la broche (1 = 5V, 0 = 0V)
        RELAY_PUMP_PIN = is_pump_active ? 1 : 0; // "Condition ? si_vrai : si_faux" (opérateur ternaire)

        // --- GESTION DE L'AFFICHAGE LCD (Mode Normal vs Info) ---
        // Si Interrupteur 3 est fermé (0V) -> Affichage technique
        if (SW_INFO_MODE == 0) {
            LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
            // sprintf crée une phrase "à trous" et met le résultat dans 'lcd_buffer'
            // %04u : Insère une variable Unsigned (entière positive), sur 4 chiffres en forçant des 0 devant (ex: 0512)
            // %s   : Insère une chaîne de texte ("ON " ou "OFF")
            sprintf(lcd_buffer, "ADC:%04u PMP:%s", current_adc_value, is_pump_active ? "ON " : "OFF");
            LCD_String(I2C_LCD_ADDR, lcd_buffer); // Envoie la phrase terminée à l'écran
            
            LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
            // %3u%% : 3 caractères pour le chiffre, suivi du symbole % écrit deux fois pour s'afficher
            sprintf(lcd_buffer, "Humidite: %3u%%  ", current_humidity_percent);
            LCD_String(I2C_LCD_ADDR, lcd_buffer);
        } 
        else {
            // Mode Normal (Grand public)
            LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
            sprintf(lcd_buffer, "Terre : %3u%%   ", current_humidity_percent);
            LCD_String(I2C_LCD_ADDR, lcd_buffer);
            
            LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
            if(is_pump_active) {
                LCD_String(I2C_LCD_ADDR, "-> ARROSAGE ON  ");
            } else {
                LCD_String(I2C_LCD_ADDR, "-> ATTENTE      ");
            }
        }

        // Fait une pause de 1 seconde avant de reprendre la mesure (économie d'énergie)
        __delay_ms(1000); 
    }
}

// ============================================================================
// IMPLÉMENTATION DES FONCTIONS SYSTÈME
// ============================================================================

/**
 * @brief Configure les directions des ports, les résistances internes et le convertisseur (ADC)
 */
void System_Initialize(void) {
    // --- PORT A (Capteur d'humidité) ---
    // TRIS = Direction (1 = In, 0 = Out). ANSEL = Analog Select (1 = Analog, 0 = Digital).
    TRISAbits.TRISA0 = 1;     // RA0 doit "écouter" la tension (Entrée)
    ANSELAbits.ANSELA0 = 1;   // RA0 traitera le signal comme une variation continue (Analogique)
    TRISAbits.TRISA1 = 0;     // RA1 va fournir du courant au capteur (Sortie)
    ANSELAbits.ANSELA1 = 0;   // RA1 sera juste du 5V On/Off (Numérique)
    HYGRO_POWER_PIN = 0;      // Assure que le capteur est éteint au démarrage
    
    // --- PORT B (Interrupteurs) ---
    // 0b indique un nombre binaire. 0b00000111 = bits 0, 1 et 2 mis à 1.
    TRISB = 0b00000111;       // RB0, RB1, RB2 configurés comme entrées (pour lire les boutons)
    ANSELB = 0x00;            // 0x00 = Hexadécimal pour "tout à 0". Désactive l'analogique sur tout le port.
    WPUB = 0b00000111;        // WPUB (Weak Pull-Up Port B) active les petites résistances internes au 5V.
    
    // --- PORT C (I2C) ---
    // Configuration repoussée dans I2C_Init() pour séparer les tâches.
    
    // --- PORT D (Relais et LEDs) ---
    TRISD = 0x00;             // Les LEDs et le Relais ont besoin de recevoir du courant (Tout en sortie)
    ANSELD = 0x00;            // Le port D fonctionne en 0V / 5V franc (Numérique)
    LATD = 0x00;              // Eteint tout par précaution au démarrage

    // --- INITIALISATION ADC (Analog to Digital Converter) ---
    // Sur le PIC18-Q84, le registre s'appelle ADCON0.
    ADCON0bits.ON = 1;        // Réveille le module de conversion
    ADCON0bits.FM = 1;        // FM = Format Mode. 1 = Résultat collé à droite (Facilite le calcul sur 12 bits)
    ADCON0bits.CS = 1;        // Clock Select = 1 (Utilise l'horloge interne dédiée HFINTOSC)
    ADCLK = 0x3F;             // Règle la vitesse du convertisseur (un chronomètre trop rapide fait des erreurs de lecture)
    ADPCH = 0x00;             // ADPCH (ADC Positive Channel) sélectionne l'entrée à mesurer : 0x00 correspond à ANA0 (Broche RA0)
}

/**
 * @brief  Active le capteur, lit la tension convertie en chiffre, et le recoupe (anti-électrolyse)
 * @return Un chiffre entre 0 et 4095 proportionnel à la tension lue.
 */
uint16_t ADC_Read_Humidity(void) {
    uint16_t result = 0;      // Crée une variable de 16 bits (pouvant aller jusqu'à 65535)
    
    HYGRO_POWER_PIN = 1;      // Envoie du 5V sur RA1 pour réveiller le capteur
    __delay_ms(15);           // Laisse 15 millisecondes à l'électronique du capteur pour se stabiliser
    
    ADCON0bits.GO = 1;        // Appuie sur le bouton "Start" de la conversion analogique
    while(ADCON0bits.GO);     // Le PIC remettra ce bit à 0 tout seul quand il aura fini. On attend en boucle (while).
    
    // Le composant Q84 a un convertisseur 12 bits (résultat de 0 à 4095).
    // Mais les registres du PIC ne font que 8 bits de large !
    // Le résultat est donc coupé en deux morceaux : ADRESH (High) et ADRESL (Low).
    // << 8 décale la partie haute de 8 cases vers la gauche, puis on recolle (|) la partie basse.
    result = ((uint16_t)ADRESH << 8) | ADRESL;
    
    HYGRO_POWER_PIN = 0;      // Coupe instantanément l'alimentation du capteur (le sauve de la corrosion)
    return result;
}

// ============================================================================
// IMPLÉMENTATION I2C LOGICIEL (BIT-BANGING)
// ============================================================================
// Le protocole I2C manipule manuellement (Bit-Banging) deux fils :
// SCL (Clock/Horloge) qui donne le tempo.
// SDA (Data/Données) qui envoie les 1 et les 0.

/**
 * @brief Configure les broches pour le réseau manuel I2C
 */
void I2C_Init(void) {
    ANSELCbits.ANSELC3 = 0; // Pas d'analogique sur les broches de communication
    ANSELCbits.ANSELC4 = 0;
    
    // On met en permanence les verrous de sortie à 0V (Masse).
    // La "magie" du bit-banging I2C consiste à basculer la broche entre :
    // - Entrée (flottante) = lue comme '1' car les résistances de votre montage tirent vers 5V.
    // - Sortie (Liée au LATCH 0) = lue comme '0' car on écrase le 5V vers la masse.
    I2C_SDA_LAT = 0;
    I2C_SCL_LAT = 0;
    I2C_SDA_DIR = 1;        // Repos = Direction Entrée (Ligne à 5V via résistances)
    I2C_SCL_DIR = 1;
}

/**
 * @brief Gère la séquence d'ouverture de discussion "START" sur le réseau I2C
 */
void I2C_Start(void) {
    I2C_SDA_DIR = 0; I2C_SDA_LAT = 0; // Tire la ligne de données à 0V pendant que l'horloge est à 5V (Signal conventionnel "Start")
    __delay_us(5);                    // Attend 5 microsecondes
    I2C_SCL_DIR = 0; I2C_SCL_LAT = 0; // Descend l'horloge à 0V. Le réseau est pris.
    __delay_us(5);
}

/**
 * @brief Gère la séquence de fin de discussion "STOP" sur le réseau I2C
 */
void I2C_Stop(void) {
    I2C_SDA_DIR = 0; I2C_SDA_LAT = 0;
    __delay_us(5);
    I2C_SCL_DIR = 1;                  // Remonte l'horloge en premier
    __delay_us(5);
    I2C_SDA_DIR = 1;                  // Remonte les données en second (Signal conventionnel "Stop")
    __delay_us(5);
}

/**
 * @brief Envoie un octet (8 bits) sur le réseau fil par fil
 */
void I2C_Write(uint8_t data) {
    // Boucle for : s'exécute 8 fois (une fois par bit)
    for (uint8_t i = 0; i < 8; i++) {
        
        // Opération ET logique (Masque). 0x80 = 0b10000000.
        // Si le bit tout à gauche de 'data' est un 1, on relâche la ligne (passe à 5V)
        if (data & 0x80) I2C_SDA_DIR = 1; 
        // Sinon on tire la ligne à la masse (passe à 0V)
        else { I2C_SDA_DIR = 0; I2C_SDA_LAT = 0; } 
        
        __delay_us(5);
        I2C_SCL_DIR = 1; // "Coup d'horloge" en haut : indique à l'écran qu'il peut lire le bit
        __delay_us(5);
        I2C_SCL_DIR = 0; I2C_SCL_LAT = 0; // On redescend l'horloge
        __delay_us(5);
        
        // Décale tous les bits de la variable 'data' d'un cran vers la gauche.
        // Au prochain tour, le 2ème bit deviendra le 1er bit, etc.
        data <<= 1;
    }
    
    // Le 9ème bit en I2C est le bit "ACK" (Acknowledge) de l'esclave pour dire "J'ai bien reçu".
    // On relâche la ligne SDA pour laisser l'écran répondre.
    I2C_SDA_DIR = 1; 
    __delay_us(5);
    I2C_SCL_DIR = 1; __delay_us(5); // Coup d'horloge pour le bit ACK
    I2C_SCL_DIR = 0; I2C_SCL_LAT = 0;
    __delay_us(5);
}

// ============================================================================
// IMPLÉMENTATION LCD (PCF8574 - Le composant noir collé derrière votre écran)
// ============================================================================

/**
 * @brief Le bus I2C permet juste d'envoyer 8 pins. Cette fonction découpe nos données
 * pour simuler le comportement du vieux contrôleur LCD standard (qui demande de couper
 * l'envoi en deux paquets de 4 bits, appelés "Nibbles").
 */
void LCD_Send_Nibble(uint8_t i2c_addr, uint8_t data, uint8_t rs) {
    // rs = Register Select (0 = Ordre système pour l'écran, 1 = Lettre à afficher)
    // 0x08 = 0b00001000. Ce bit allume la LED de rétroéclairage de votre écran LCD.
    uint8_t pcf_data = data | rs | 0x08; 
    
    I2C_Start();
    
    // L'adresse I2C (ex 0x27) est sur 7 bits. Le protocole I2C demande de la décaler vers la gauche
    // et d'ajouter un 0 à la fin pour signifier "Je veux ÉCRIRE".
    I2C_Write(i2c_addr << 1); 
    
    // 0x04 = 0b00000100. C'est le bit "EN" (Enable). On monte ce bit pour réveiller l'écran.
    I2C_Write(pcf_data | 0x04); 
    __delay_us(50);
    
    I2C_Start();              // Redémarrage exigé par la norme
    I2C_Write(i2c_addr << 1);
    
    // 0xFB = 0b11111011. L'opérateur ET logique (&) force le bit EN à 0. 
    // En redescendant, l'écran "valide" la lecture de la donnée.
    I2C_Write(pcf_data & 0xFB); 
    I2C_Stop();
    __delay_us(50);
}

/**
 * @brief Envoie un ordre technique à l'écran (ex: s'effacer, bouger le curseur)
 */
void LCD_Command(uint8_t i2c_addr, uint8_t cmd) {
    // On masque (0xF0) et on envoie la partie HAUTE de l'octet, RS = 0 (car c'est une commande)
    LCD_Send_Nibble(i2c_addr, cmd & 0xF0, 0);       
    // On décale de 4 crans et on envoie la partie BASSE de l'octet.
    LCD_Send_Nibble(i2c_addr, (cmd << 4) & 0xF0, 0); 
    __delay_ms(2);
}

/**
 * @brief Envoie un caractère visible à l'écran (ex: 'A')
 */
void LCD_Char(uint8_t i2c_addr, char data) {
    // Même principe, mais avec RS = 1 (car on envoie une donnée à dessiner)
    LCD_Send_Nibble(i2c_addr, data & 0xF0, 1);       
    LCD_Send_Nibble(i2c_addr, (data << 4) & 0xF0, 1); 
    __delay_us(50);
}

/**
 * @brief Séquence magique requise par le fabricant de l'écran pour l'allumer correctement
 */
void LCD_Init(uint8_t i2c_addr) {
    __delay_ms(50);
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(5);
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(1);
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(1);
    LCD_Send_Nibble(i2c_addr, 0x20, 0); __delay_ms(1); // Bascule l'écran en mode 4 bits
    
    // Envoi des commandes de configuration du visuel
    LCD_Command(i2c_addr, 0x28); // Précise qu'on a un écran 2 lignes
    LCD_Command(i2c_addr, 0x0C); // Demande d'allumer l'écran, mais de cacher le petit trait clignotant (curseur)
    LCD_Command(i2c_addr, 0x06); // Demande à l'écran de se décaler vers la droite à chaque lettre
    LCD_Clear(i2c_addr);         // Vide tout
}

/**
 * @brief Déplace le curseur d'écriture invisible à des coordonnées X,Y
 */
void LCD_SetCursor(uint8_t i2c_addr, uint8_t row, uint8_t col) {
    uint8_t address;
    // 0x80 est l'adresse mémoire de la 1ère case en haut à gauche
    // 0xC0 est l'adresse mémoire de la 1ère case en bas à gauche
    if (row == 1) address = 0x80 + col - 1;
    else          address = 0xC0 + col - 1;
    
    LCD_Command(i2c_addr, address);
}

/**
 * @brief Efface tous les pixels de l'écran
 */
void LCD_Clear(uint8_t i2c_addr) {
    LCD_Command(i2c_addr, 0x01); // 0x01 est l'ordre universel d'effacement pour cet écran
    __delay_ms(2);               // L'effacement est long, il faut attendre 2ms
}

/**
 * @brief Prends un texte complet (ex: "Bonjour") et l'envoie lettre par lettre
 */
void LCD_String(uint8_t i2c_addr, const char *str) {
    // La boucle "while(*str)" tourne tant qu'on n'est pas arrivé à la fin du texte (caractère nul '\0')
    while (*str) {
        // Envoie la lettre actuelle, puis avance au caractère suivant (le fameux 'str++')
        LCD_Char(i2c_addr, *str++);
    }
}