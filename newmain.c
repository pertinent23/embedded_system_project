#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

// ============================================================================
// CONFIGURATION DU MICROCONTRÔLEUR (FUSES / BITS DE CONFIGURATION)
// ============================================================================
#pragma config FEXTOSC  = OFF           ///< Désactive l'attente d'un quartz externe (Gain de place/stabilité)
#pragma config RSTOSC   = HFINTOSC_64MHZ///< Démarre directement sur l'horloge interne à 64 MHz (Vitesse max)
#pragma config WDTE     = OFF           ///< Désactive le chien de garde (Watchdog) pour éviter les resets intempestifs
#pragma config LVP      = ON            ///< Autorise la programmation en basse tension (Standard actuel)
#pragma config MCLRE    = INTMCLR       ///< Désactive le reset matériel sur la broche 1 (La broche devient une entrée classique)
#pragma config MVECEN   = OFF           ///< IMPORTANT: Désactive le mode d'interruption vectoriel (Utilise le mode Legacy compatible avec __interrupt())

// ============================================================================
// DÉFINITIONS ET CONSTANTES SYSTÈME
// ============================================================================
#define _XTAL_FREQ          64000000    ///< Définit la fréquence pour les fonctions __delay_ms() (64 MHz)
#define I2C_LCD_ADDR        0x27        ///< Adresse matérielle I2C de la puce PCF8574 (Écran LCD)

// --- Paramètres de Calibration du Capteur Capacitif ---
#define ADC_SEC_MAX         4095        ///< Valeur brute lue dans l'air sec (0% d'humidité)
#define ADC_HUMIDE_TARGET   750         ///< Valeur brute lue dans la terre cible (100% d'humidité)

// --- Paramètres de Régulation de l'Arrosage ---
#define PUMP_ON_THRESHOLD   40          ///< Seuil bas : Active la pompe si l'humidité descend à ou sous 40%
#define PUMP_OFF_THRESHOLD  85          ///< Seuil haut : Coupe la pompe dès que l'humidité remonte à 85%

// --- Paramètres de l'Interface Utilisateur ---
#define SLIDE_DURATION      4           ///< Durée d'affichage (en secondes) pour chaque écran du diaporama
#define ADC_SAMPLES         100         ///< Nombre de mesures consécutives pour calculer la moyenne glissante

// ============================================================================
// MAPPAGE MATÉRIEL (HARDWARE ABSTRACTION)
// ============================================================================
// --- Sorties de puissance ---
#define HYGRO_POWER_PIN     LATA1       ///< Pin 3  (RA1) : Contrôle l'alimentation du capteur d'humidité
#define RELAY_PUMP_PIN      LATD0       ///< Pin 19 (RD0) : Commande du module relais (0 = Pompe ON, 1 = Pompe OFF)
#define LED_GREEN_PIN       LATD1       ///< Pin 20 (RD1) : LED d'état de fonctionnement normal
#define LED_RED_PIN         LATD2       ///< Pin 21 (RD2) : LED d'état de veille ou d'arrêt

// --- Entrées utilisateurs (Boutons actifs à l'état bas / 0V) ---
#define SW_SYSTEM_OFF       RB0         ///< Pin 33 (RB0) : Bouton 1 - Interrupteur général (1 = OFF, 0 = ON)
#define SW_MANUAL_PUMP      RB1         ///< Pin 34 (RB1) : Bouton 2 - Forçage manuel de la pompe
#define SW_INFO_MODE        RB2         ///< Pin 35 (RB2) : Bouton 3 - Mode diaporama d'informations

// --- Bus I2C (Bit-Banging) ---
#define I2C_SCL_LAT         LATC3       ///< Registre d'état du signal d'horloge I2C
#define I2C_SDA_LAT         LATC4       ///< Registre d'état du signal de données I2C
#define I2C_SCL_DIR         TRISC3      ///< Registre de direction (TRIS) pour générer l'horloge I2C
#define I2C_SDA_DIR         TRISC4      ///< Registre de direction (TRIS) pour générer les données I2C

#define SLEEP_DELAY 4             // Temps avant extinction (ex: 10 secondes)
// ============================================================================
// VARIABLES GLOBALES (CONTEXTE D'EXÉCUTION)
// ============================================================================
/** @name Horloge Logicielle (RTC) Modifiée par l'interruption */
volatile uint8_t  seconds = 0, minutes = 0, hours = 12;
volatile uint8_t  day = 1, month = 1;
volatile uint16_t year = 2024;
volatile uint32_t uptime_minutes = 0;   ///< Compteur de temps de fonctionnement total depuis l'allumage

/** @name Traitement du Signal (Capteur) */
uint16_t raw_moisture = 0;              ///< Dernière valeur brute lissée (0-4095)
uint8_t  humidity_percent = 0;          ///< Pourcentage d'humidité déduit après calibration

/** @name État des Actionneurs */
bool     pump_state = false;            ///< Flag booléen représentant l'état logique désiré de la pompe (true = allumée)
volatile uint16_t manual_chrono_sec = 0;///< Compteur en secondes du temps de forçage manuel de la pompe

/** @name Gestion de l'Interface Graphique (LCD) */
volatile uint8_t slide_timer = 0;       ///< Compteur de secondes pour déclencher le changement d'écran
uint8_t current_info_slide = 0;         ///< Index de l'écran actuel en mode Info (0 à 3)
uint8_t current_off_slide  = 0;         ///< Index de l'écran actuel en mode Veille (0 à 1)
char lcd_line1[17], lcd_line2[17];      ///< Buffers de 16 caractères (+ caractère de fin de chaîne \0) pour préparer l'affichage
bool backlight_status = true; ///< true = Allumé, false = Éteint
uint8_t sleep_timeout_counter = 0; // Compteur pour l'extinction automatique

// ============================================================================
// DÉCLARATION DES FONCTIONS (PROTOTYPES)
// ============================================================================
void System_Initialize(void);
void Timer0_Initialize(void);
uint16_t ADC_Read_Moisture(void);
void Update_Display(void);
void System_Control_Logic(void);

// Routines I2C et LCD bas niveau
void I2C_Init(void);
void I2C_Start(void);
void I2C_Stop(void);
void I2C_Write(uint8_t data);
void LCD_Init(void);
void LCD_Command(uint8_t cmd);
void LCD_Char(char data);
void LCD_String(const char *str);
void LCD_SetCursor(uint8_t row, uint8_t col);

// ============================================================================
// GESTION DES INTERRUPTIONS
// ============================================================================
/**
 * @brief  Routine de service d'interruption (ISR) de haute priorité.
 * @details Gère les débordements du Timer0 pour créer une base de temps d'exactement 1 seconde.
 * Gère l'horloge (RTC), les compteurs de temps et la logique de changement de slide.
 */
void __interrupt() High_ISR(void) {
    // Vérifie si l'interruption provient bien du débordement du Timer0
    if (TMR0IF) {
        
        seconds++;      // Incrémente les secondes de l'horloge
        slide_timer++;  // Incrémente le timer du diaporama

        // Si le système est OFF, on compte les secondes avant de dormir
        if (SW_SYSTEM_OFF == 1 && sleep_timeout_counter < SLEEP_DELAY) {
            sleep_timeout_counter++;
        }

        // Si la pompe tourne en forçage manuel (et que le système n'est pas éteint), on compte le temps
        if (pump_state && SW_MANUAL_PUMP == 0 && SW_SYSTEM_OFF == 0) {
            manual_chrono_sec++;
        }

        // --- Logique du Calendrier (Cascade temporelle) ---
        if (seconds >= 60) {
            seconds = 0; 
            minutes++; 
            uptime_minutes++; // Compte le temps total d'activité
        }
        if (minutes >= 60) {
            minutes = 0; 
            hours++;
        }
        if (hours >= 24) {
            hours = 0; 
            day++;
        }
        
        // --- Bascule Automatique des Écrans LCD ---
        if (slide_timer >= SLIDE_DURATION) {
            slide_timer = 0; // Réinitialise le compteur d'attente
            current_info_slide = (current_info_slide + 1) % 4; // Boucle sur 4 slides (0, 1, 2, 3)
            current_off_slide  = (current_off_slide + 1) % 2;  // Boucle sur 2 slides (0, 1)
        }

        // --- Réarmement du Timer0 ---
        // Recharge les registres pour générer précisément 1 seconde de délai au prochain cycle
        TMR0H = 0x0B; 
        TMR0L = 0xDC; 
        
        TMR0IF = 0; // Baisse le drapeau (flag) d'interruption pour autoriser la suivante
    }
}

// ============================================================================
// PROGRAMME PRINCIPAL
// ============================================================================
/**
 * @brief Point d'entrée de l'application. Initialise le système et exécute la boucle infinie.
 */
void main(void) {
    // 1. Appel des routines d'initialisation matérielle
    System_Initialize();
    I2C_Init();
    LCD_Init();
    Timer0_Initialize();
    
    // 2. Démarrage du moteur d'interruption
    INTCON0bits.GIE = 1; ///< Global Interrupt Enable (Autorise l'ISR à s'exécuter en arrière-plan)

    // 3. Affichage de l'écran de démarrage (Splash Screen)
    LCD_SetCursor(1, 1); 
    LCD_String("  FIRMWARE V3.1 ");
    LCD_SetCursor(2, 1); 
    LCD_String(" Initialisation ");
    __delay_ms(1500); // Pause pour laisser l'utilisateur lire

    // 4. Boucle infinie d'exécution (Ordonnanceur principal)
    while (1) {
        
        // --- ÉTAPE A : Acquisition Analogique ---
        raw_moisture = ADC_Read_Moisture();
        
        // --- ÉTAPE B : Calcul Mathématique Borne (Sécurité) ---
        uint16_t temp_adc = raw_moisture;
        if(temp_adc > ADC_SEC_MAX) temp_adc = ADC_SEC_MAX;             // Borne haute (Sec)
        if(temp_adc < ADC_HUMIDE_TARGET) temp_adc = ADC_HUMIDE_TARGET; // Borne basse (Humide)
        
        // Conversion de l'échelle inversée du capteur (4095->750) vers un pourcentage (0%->100%)
        humidity_percent = 100 - ((uint32_t)(temp_adc - ADC_HUMIDE_TARGET) * 100) / (ADC_SEC_MAX - ADC_HUMIDE_TARGET);

        // --- ÉTAPE C : Logique Décisionnelle ---
        System_Control_Logic(); // Calcule l'état attendu de la pompe et des LEDs

        // --- ÉTAPE D : Mise à jour de l'Interface Homme-Machine ---
        Update_Display(); // Génère les textes et les envoie à l'écran LCD
        
        // --- ÉTAPE E : Pause pour stabiliser la boucle ---
        __delay_ms(100); 
    }
}

// ============================================================================
// COUCHE APPLICATIVE (LOGIQUE MÉTIER ET IHM)
// ============================================================================

/**
 * @brief  Cœur de la logique décisionnelle corrigé.
 * @details Ajout d'une extinction automatique lors du relâchement du forçage.
 */
void System_Control_Logic(void) {
    // --- PRIORITÉ 1 : SYSTÈME COUPÉ ---
    if (SW_SYSTEM_OFF == 1) {
        pump_state = false;
        manual_chrono_sec = 0; 
        LED_GREEN_PIN = 0;
        LED_RED_PIN = 1;       
        RELAY_PUMP_PIN = 1;    // Sécurité physique
        return;                
    }
    
    // --- PRIORITÉ 2 : SYSTÈME ACTIF ---
    LED_GREEN_PIN = 1;
    LED_RED_PIN = 0;

    // Règle 2.1 : Forçage manuel
    if (SW_MANUAL_PUMP == 0) { 
        pump_state = true;
    } 
    // Règle 2.2 : Gestion automatique
    else {
        manual_chrono_sec = 0; 
        
        // --- CORRECTION ICI ---
        // Si on vient de lâcher le bouton et que l'humidité est DEJA au-dessus 
        // du seuil critique (40%), on doit éteindre la pompe.
        if (humidity_percent > PUMP_ON_THRESHOLD && pump_state == true && manual_chrono_sec == 0) {
            // Option A : Extinction immédiate si on n'est pas en zone de sécheresse
            pump_state = false; 
        }

        // Logique auto standard
        if (humidity_percent <= PUMP_ON_THRESHOLD) {
            pump_state = true;
        } else if (humidity_percent >= PUMP_OFF_THRESHOLD) {
            pump_state = false;
        }
    }
    
    // Application physique
    RELAY_PUMP_PIN = (pump_state) ? 0 : 1; 
}

/**
 * @brief  Machine à états gérant le rendu visuel sur l'écran LCD.
 * @details Utilise sprintf pour formater des chaînes de 16 caractères afin d'écraser l'ancien
 * texte sans avoir besoin d'utiliser LCD_Clear() (ce qui évite le scintillement).
 */
void Update_Display(void) {
    // --- MODE 1 : SYSTÈME ÉTEINT (Gestion Veille et Erreurs) ---
    if (SW_SYSTEM_OFF == 1) {
        // Si le temps est écoulé, on éteint la lumière
        if (sleep_timeout_counter >= SLEEP_DELAY) {
            backlight_status = false;
        } else {
            backlight_status = true; // Reste allumé pendant le compte à rebours
        }
        
        // Si l'un des deux est à 0 (appuyé) alors que le système est OFF
        if (SW_MANUAL_PUMP == 0 || SW_INFO_MODE == 0) {
            sleep_timeout_counter = 0;
            backlight_status = true;
            LCD_SetCursor(1, 1);
            LCD_String(" ACTION REFUSEE "); ///< Message d'erreur pro
            
            LCD_SetCursor(2, 1);
            // On affiche un message d'instruction qui clignote (via le chrono des secondes)
            if (seconds % 2 == 0) {
                LCD_String(" ACTIVEZ BOUTON1"); 
            } else {
                LCD_String(" SYSTEME SUR OFF");
            }
            return; // On quitte la fonction ici pour ne pas afficher le diaporama de veille
        }

        // Si aucun bouton n'est touché, on affiche le diaporama de veille classique (2 slides)

        LCD_SetCursor(1, 1);
        LCD_String("  MODE VEILLE   ");
        
        LCD_SetCursor(2, 1);
        switch(current_off_slide) {
            case 0: sprintf(lcd_line2, "   Zz.z.z.z..   "); break;
            case 1: sprintf(lcd_line2, " POMPE INACTIVE "); break;
        }
        LCD_String(lcd_line2);
        return;
    }

    backlight_status = true; // Allume le rétroéclairage dès que le système est actif
    sleep_timeout_counter = 0;    // Reset du timer de veille

    // --- MODE 2 : FORÇAGE MANUEL (Chronomètre) ---
    if (SW_MANUAL_PUMP == 0) {
        LCD_SetCursor(1, 1);
        LCD_String(" FORCAGE MANUEL ");
        
        LCD_SetCursor(2, 1);
        // Calcule les minutes (sec / 60) et les secondes restantes (sec % 60)
        sprintf(lcd_line2, " DURIE: %02dm %02ds ", manual_chrono_sec / 60, manual_chrono_sec % 60);
        LCD_String(lcd_line2);
        return;
    }

    // --- MODE 3 : DIAPORAMA D'INFORMATIONS (Expert) ---
    if (SW_INFO_MODE == 0) {
        switch(current_info_slide) {
            case 0: // Slide Horloge
                // EFFET CLIGNOTANT : On n'affiche le texte qu'une seconde sur deux
                if (seconds % 2 == 0) {
                    sprintf(lcd_line1, "DATE: %02d/%02d/%04d", day, month, year);
                    sprintf(lcd_line2, "HEURE: %02d:%02d:%02d ", hours, minutes, seconds);
                } else {
                    // On remplit de blocs vides pour "effacer" sans utiliser LCD_Clear
                    sprintf(lcd_line1, "DATE: %02d %02d %04d", day, month, year);
                    sprintf(lcd_line2, "HEURE: %02d %02d %02d ", hours, minutes, seconds);
                }
                break;
            case 1: // Slide Diagnostic Matériel
                sprintf(lcd_line1, "BRUT ADC: %04u  ", raw_moisture);
                sprintf(lcd_line2, "RELAIS: %s    ", pump_state ? "ACTIVE " : "FERME  ");
                break;
            case 2: // Slide Configuration
                sprintf(lcd_line1, "CIBLE : %02d%%-%02d%% ", PUMP_ON_THRESHOLD, PUMP_OFF_THRESHOLD);
                sprintf(lcd_line2, "CAPTEUR : OK    ");
                break;
            case 3: // Slide Maintenance
                sprintf(lcd_line1, "UPTIME (Heures) ");
                sprintf(lcd_line2, "-> %04lu h %02lu m  ", uptime_minutes / 60, uptime_minutes % 60);
                break;
        }
        // Envoi des deux lignes générées
        LCD_SetCursor(1, 1); LCD_String(lcd_line1);
        LCD_SetCursor(2, 1); LCD_String(lcd_line2);
        return;
    } 
    
    // --- MODE 4 : AFFICHAGE NORMAL (Tableau de bord par défaut) ---
    LCD_SetCursor(1, 1);
    sprintf(lcd_line1, "TERRE : %3u%%    ", humidity_percent); // %3u garantit que les centaines prennent toujours 3 espaces
    LCD_String(lcd_line1);
    
    LCD_SetCursor(2, 1);
    if (pump_state) LCD_String("-> ARROSAGE...  ");
    else            LCD_String("-> SYSTEME OK   ");
}

// ============================================================================
// COUCHE D'ABSTRACTION MATÉRIELLE (HAL - INITIALISATIONS ET PILOTES)
// ============================================================================

/**
 * @brief Configure la direction (TRIS), le type (ANSEL) et l'état initial (LAT) des broches.
 * Configure également le Convertisseur Analogique-Numérique (ADCC) du PIC18-Q84.
 */
void System_Initialize(void) {
    // --- Configuration du Port A (Capteur) ---
    TRISA = 0b00000100;  ///< RA2 (Pin 4) en Entrée (1), les autres en Sorties (0)
    ANSELA = 0b00000100; ///< RA2 défini comme broche Analogique
    LATA = 0x00;         ///< Force toutes les sorties à 0V au démarrage
    
    // --- Configuration de l'ADC (Analog to Digital Converter) ---
    ADCON0 = 0x00; ADCON1 = 0x00; ADCON2 = 0x00; ADCON3 = 0x00; // Reset complet des registres
    
    ADCON0bits.ON = 1;      ///< Active le module convertisseur
    ADCON0bits.CS = 1;      ///< Utilise l'oscillateur interne dédié à l'ADC (ADCRC)
    ADCON0bits.FM = 1;      ///< Format de résultat justifié à droite (Lit les 12 bits sous forme 0-4095)
    
    ADREF = 0x00;           ///< Fixe les tensions de référence sur VDD (5V) et VSS (0V)
    ADPCH = 0x02;           ///< Pointeur de canal : Sélectionne l'entrée analogique ANA2 (Broche RA2 / Pin 4)
    ADACQ = 0x20;           ///< Temps d'acquisition (laisse le temps au condensateur interne de se charger)
    
    // --- Configuration du Port D (Actionneurs et LEDs) ---
    TRISD = 0x00;           ///< Toutes les broches du Port D en Sorties
    ANSELD = 0x00;          ///< Toutes les broches du Port D en Numériques (Désactive l'analogique)
    LATD = 0x01;            ///< Force la broche RD0 (Relais) à l'état Haut (1) pour s'assurer que la pompe est éteinte
    
    // --- Configuration du Port B (Boutons) ---
    TRISB = 0b00000111;     ///< RB0, RB1, RB2 configurés en Entrées (1)
    ANSELB = 0x00;          ///< Désactive l'analogique sur les boutons
    WPUB = 0b00000111;      ///< Active les résistances de Pull-up (Tirage au 5V) internes sur RB0, RB1, RB2
}

/**
 * @brief Configure le Timer0 pour déclencher une interruption chaque seconde.
 */
void Timer0_Initialize(void) {
    T0CON0 = 0x90;          ///< Timer0 activé (Bit 7), Mode 16-bit (Bit 4), Postscaler 1:1
    T0CON1 = 0x48;          ///< Source d'horloge: Fosc/4 (16 MHz), Prescaler: 1:256. L'horloge du Timer tourne à 62.5 kHz.
    
    // Math : Pour obtenir 1 sec à 62500 Hz, le timer doit compter de 65536 - 62500 = 3036.
    // 3036 en hexadécimal correspond à 0x0BDC.
    TMR0H = 0x0B; ///< Octet de poids fort (High byte)
    TMR0L = 0xDC; ///< Octet de poids faible (Low byte)
    
    TMR0IE = 1;             ///< Timer0 Interrupt Enable (Autorise l'interruption)
}

/**
 * @brief  Effectue une lecture lissée du capteur pour éliminer les parasites (bruit électrique).
 * @return uint16_t Résultat moyenné de l'humidité brute (0 - 4095).
 */
uint16_t ADC_Read_Moisture(void) {
    uint32_t total = 0;     ///< Utilisation d'un entier 32 bits pour éviter le débordement lors de l'addition
    
    HYGRO_POWER_PIN = 1;    ///< Alimente physiquement le capteur d'humidité
    __delay_ms(50);         ///< Pause de 50ms pour laisser l'électronique du capteur (Puce 555) se stabiliser
    
    // Boucle de prélèvement (Prend 100 mesures)
    for(uint8_t i = 0; i < ADC_SAMPLES; i++) {
        ADCON0bits.GO = 1;      ///< Lance la conversion ADC
        while(ADCON0bits.GO);   ///< Attend passivement que le bit retombe à 0 (Fin de conversion)
        
        // Assemble les deux registres 8 bits de résultat (ADRESH et ADRESL) en un seul nombre 16 bits
        total += ((uint16_t)ADRESH << 8) | ADRESL;
        
        __delay_us(100);        ///< Petite pause de 100 microsecondes entre chaque échantillon
    }
    
    HYGRO_POWER_PIN = 0;    ///< Coupe l'alimentation du capteur (Préserve l'énergie et limite l'oxydation des capteurs de mauvaise qualité)
    
    return (uint16_t)(total / ADC_SAMPLES); ///< Divise par 100 pour obtenir la moyenne stricte
}

// ============================================================================
// PILOTES BAS NIVEAU : I2C BIT-BANGING & ÉCRAN LCD
// ============================================================================
// Note : Le bus I2C matériel n'est pas utilisé ici. Le protocole est recréé "à la main"
// en modifiant rapidement les broches SCL et SDA (Technique du Bit-Banging).

/** @brief Prépare les broches I2C pour le Bit-Banging */
void I2C_Init(void) { 
    ANSELC = 0;         ///< RC3 et RC4 en numérique
    
    I2C_SCL_LAT = 0;    ///< Force le niveau de sortie à 0V en permanence
    I2C_SDA_LAT = 0;    ///< Force le niveau de sortie à 0V en permanence
    // -------------------------------
    
    I2C_SCL_DIR = 1;    ///< Met l'horloge en entrée (Relâche la ligne au 5V via Pull-up)
    I2C_SDA_DIR = 1;    ///< Met la donnée en entrée (Relâche la ligne)
}

/** @brief Génère la condition de START (SDA passe bas pendant que SCL est haut) */
void I2C_Start(void) { 
    I2C_SDA_DIR = 0; __delay_us(20); 
    I2C_SCL_DIR = 0; __delay_us(20); 
}

/** @brief Génère la condition de STOP (SDA passe haut pendant que SCL est haut) */
void I2C_Stop(void) { 
    I2C_SDA_DIR = 0; __delay_us(20); 
    I2C_SCL_DIR = 1; __delay_us(20); 
    I2C_SDA_DIR = 1; __delay_us(20); 
}

/** @brief Écrit un octet (8 bits) sur le bus I2C bit par bit */
void I2C_Write(uint8_t data) {
    for(int i = 0; i < 8; i++) { 
        // Sélectionne le bit à envoyer (1 ou 0)
        if(data & 0x80) I2C_SDA_DIR = 1; 
        else            I2C_SDA_DIR = 0; 
        
        __delay_us(10); 
        I2C_SCL_DIR = 1; __delay_us(10); ///< Création de l'impulsion d'horloge (Haut)
        I2C_SCL_DIR = 0; __delay_us(10); ///< Descente de l'horloge (Bas)
        
        data <<= 1; ///< Décale les bits vers la gauche pour préparer le suivant
    }
    // Gère le bit d'acquittement (ACK) envoyé par le module LCD
    I2C_SDA_DIR = 1; __delay_us(10); 
    I2C_SCL_DIR = 1; __delay_us(10); 
    I2C_SCL_DIR = 0; __delay_us(10);
}

/**
 * @brief Envoie 4 bits au LCD en respectant l'état du rétroéclairage.
 */
void LCD_Send(uint8_t data, uint8_t rs) {
    // On définit le bit du rétroéclairage (0x08 pour ON, 0x00 pour OFF)
    uint8_t backlight = (backlight_status) ? 0x08 : 0x00;
    uint8_t d = data | rs | backlight; 
    
    I2C_Start(); 
    I2C_Write(I2C_LCD_ADDR << 1); 
    I2C_Write(d); 
    I2C_Write(d | 0x04); __delay_us(10); 
    I2C_Write(d);        __delay_us(50); 
    I2C_Stop(); 
}

/** @brief Envoie une commande (Instruction) de 8 bits au LCD (Séparée en 2 blocs de 4 bits) */
void LCD_Command(uint8_t cmd) { 
    LCD_Send(cmd & 0xF0, 0);          ///< Envoie les 4 bits de poids fort (RS = 0)
    LCD_Send((cmd << 4) & 0xF0, 0);   ///< Envoie les 4 bits de poids faible (RS = 0)
    __delay_ms(2);                    ///< Pause nécessaire pour laisser l'écran traiter la commande
}

/** @brief Envoie un caractère ASCII de 8 bits au LCD pour l'affichage */
void LCD_Char(char data) { 
    LCD_Send(data & 0xF0, 1);         ///< Envoie les 4 bits de poids fort (RS = 1 pour mode Data)
    LCD_Send((data << 4) & 0xF0, 1);  ///< Envoie les 4 bits de poids faible (RS = 1)
    __delay_us(100); 
}

/** @brief Séquence d'initialisation obligatoire pour démarrer le contrôleur HD44780 de l'écran en mode 4 bits */
void LCD_Init(void) { 
    __delay_ms(100); ///< Attente du stabilisateur de tension du LCD au démarrage
    LCD_Send(0x30, 0); __delay_ms(5); 
    LCD_Send(0x30, 0); __delay_ms(1); 
    LCD_Send(0x30, 0); __delay_ms(1); 
    LCD_Send(0x20, 0); ///< Passe formellement en mode d'interface 4-bits
    
    LCD_Command(0x28); ///< Config : 2 Lignes, Police 5x8
    LCD_Command(0x0C); ///< Config : Allume l'écran, Cache le curseur, Arrête le clignotement
    LCD_Command(0x01); ///< Commande : Efface tout l'écran
    __delay_ms(5); 
}

/** @brief Déplace le curseur d'écriture à une position précise (Ligne, Colonne) */
void LCD_SetCursor(uint8_t r, uint8_t c) { 
    // Ligne 1 commence à l'adresse 0x80. Ligne 2 commence à l'adresse 0xC0.
    LCD_Command((r == 1 ? 0x80 : 0xC0) + c - 1); 
}

/** @brief Affiche une chaîne de caractères complète sur l'écran */
void LCD_String(const char *str) { 
    while(*str) {           ///< Tant qu'on n'atteint pas le caractère de fin de chaîne ('\0')
        LCD_Char(*str++);   ///< Envoie la lettre actuelle, puis avance au caractère suivant
    }
}