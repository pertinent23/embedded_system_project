#pragma config FEXTOSC = OFF        
#pragma config RSTOSC = HFINTOSC_64MHZ 
#pragma config WDTE = OFF           
#pragma config LVP = ON             

#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#define _XTAL_FREQ 64000000         
#define I2C_LCD_ADDR 0x27           

// ============================================================================
// ALIAS DES BROCHES (Syntaxe directe pour éviter les erreurs de l'éditeur XC8)
// ============================================================================
#define HYGRO_POWER_PIN     LATA1
#define RELAY_PUMP_PIN      LATD0 // Relais Optocouplé : 1=OFF, 0=ON
#define LED_GREEN_PIN       LATD1
#define LED_RED_PIN         LATD2

#define SW_SYSTEM_ON_OFF    RB0
#define SW_FORCE_PUMP       RB1
#define SW_INFO_MODE        RB2

#define I2C_SCL_LAT         LATC3
#define I2C_SDA_LAT         LATC4
#define I2C_SCL_DIR         TRISC3
#define I2C_SDA_DIR         TRISC4

// --- Seuils de calibration ---
const uint16_t ADC_SEC_MAX = 2000;   
const uint16_t ADC_HUMIDE = 1400;    

// ============================================================================
// VARIABLES ET PROTOTYPES
// ============================================================================
uint16_t current_adc_value = 0;     
uint8_t current_humidity_percent = 0; 
bool is_pump_active = false;        
char lcd_buffer[17];                

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
    // 1. Initialisation matérielle
    System_Initialize();
    I2C_Init();
    LCD_Init(I2C_LCD_ADDR);
    
    // Message de bienvenue
    LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
    LCD_String(I2C_LCD_ADDR, " Systeme Actif  ");
    LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
    LCD_String(I2C_LCD_ADDR, "Initialisation..");
    __delay_ms(2000);
    LCD_Clear(I2C_LCD_ADDR);

    // 2. Boucle infinie du système
    while (1) {
        
        // --- CAS 1 : SYSTEME SUR "OFF" ---
        if (SW_SYSTEM_ON_OFF == 1) { 
            RELAY_PUMP_PIN = 1;     // Arrêt forcé de la pompe (1 = OFF)
            LED_GREEN_PIN = 0;      
            LED_RED_PIN = 1;        // Allume la LED Rouge "Veille"
            
            // Sécurité : Avertissement si on touche aux autres boutons
            if (SW_FORCE_PUMP == 0 || SW_INFO_MODE == 0) {
                LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
                LCD_String(I2C_LCD_ADDR, "Allumer d'abord ");
                LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
                LCD_String(I2C_LCD_ADDR, "le systeme      ");
            } else {
                LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
                LCD_String(I2C_LCD_ADDR, " SYSTEME ETEINT ");
                LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
                LCD_String(I2C_LCD_ADDR, "  (Mode Veille) ");
            }
            
            __delay_ms(200);
            continue; // Recommence la boucle ici, saute la suite
        }
        
        // --- CAS 2 : SYSTEME SUR "ON" ---
        LED_GREEN_PIN = 1;
        LED_RED_PIN = 0;

        // Lecture du capteur d'humidité
        current_adc_value = ADC_Read_Humidity();
        //if(current_adc_value > ADC_SEC_MAX) current_adc_value = ADC_SEC_MAX;
        //if(current_adc_value < ADC_HUMIDE) current_adc_value = ADC_HUMIDE;
        current_humidity_percent = 100 - ((current_adc_value - ADC_HUMIDE) * 100) / (ADC_SEC_MAX - ADC_HUMIDE);

        // Logique de la pompe
        if (SW_FORCE_PUMP == 0) {
            is_pump_active = true; // Mode forçage manuel
        } else {
            // Mode automatique intelligent (basé sur le %)
            if (current_humidity_percent <= 10) {
                is_pump_active = true;  // S'allume à 30% ou moins
            } 
            else if (current_humidity_percent >= 30) {
                is_pump_active = false; // S'éteint à 80% ou plus
            }
            // Si l'humidité est entre 30% et 80%, la pompe garde son état actuel
        }
        
        // Activation physique du Relais (0 = ON, 1 = OFF)
        if (is_pump_active) RELAY_PUMP_PIN = 0; 
        else                RELAY_PUMP_PIN = 1;

        // Logique d'affichage de l'écran
        if (SW_INFO_MODE == 0) {
            // Mode Info : Affiche les données techniques
            LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
            sprintf(lcd_buffer, "ADC:%04u PMP:%s", current_adc_value, is_pump_active ? "ON " : "OFF");
            LCD_String(I2C_LCD_ADDR, lcd_buffer);
            
            LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
            sprintf(lcd_buffer, "Humidite: %3u%%  ", current_humidity_percent);
            LCD_String(I2C_LCD_ADDR, lcd_buffer);
        } else {
            // Mode Normal : Affichage grand public
            LCD_SetCursor(I2C_LCD_ADDR, 1, 1);
            sprintf(lcd_buffer, "Terre : %3u%%   ", current_humidity_percent);
            LCD_String(I2C_LCD_ADDR, lcd_buffer);
            
            LCD_SetCursor(I2C_LCD_ADDR, 2, 1);
            if(is_pump_active) LCD_String(I2C_LCD_ADDR, "-> ARROSAGE ON  ");
            else               LCD_String(I2C_LCD_ADDR, "-> ATTENTE      ");
        }

        __delay_ms(500); 
    }
}

// ============================================================================
// FONCTIONS MATÉRIELLES (Optimisées avec des masques binaires)
// ============================================================================
void System_Initialize(void) {
    // Port A : Capteur
    TRISA  = 0b00000001; // RA0 en entrée, RA1 en sortie
    ANSELA = 0b00000001; // RA0 en analogique
    LATA   = 0x00;       
    
    // Port B : Boutons
    TRISB  = 0b00000111; // RB0, RB1, RB2 en entrées
    ANSELB = 0x00;       
    WPUB   = 0b00000111; // Pull-ups activés
    
    // Port D : Relais et LEDs
    TRISD  = 0x00;       // Tout en sortie
    ANSELD = 0x00;       
    LATD   = 0x01;       // RD0 à 1 (Relais OFF par défaut)
    
    // ADC
    ADCON0 = 0b10010100; // Allumé, Horloge interne, Résultat à droite
    ADCLK  = 0x3F; 
    ADPCH  = 0x00;       // Canal ANA0 (RA0)
}

uint16_t ADC_Read_Humidity(void) {
    uint16_t result = 0;
    HYGRO_POWER_PIN = 1;
    __delay_ms(15);
    ADCON0 |= 0x01;       // Lance la conversion (Bit GO)
    while(ADCON0 & 0x01); // Attend la fin
    result = ((uint16_t)ADRESH << 8) | ADRESL;
    HYGRO_POWER_PIN = 0;
    return result;
}

// ============================================================================
// PILOTE I2C & LCD (Ultra-Stable et fluide)
// ============================================================================
void I2C_Init(void) {
    ANSELC = 0x00; 
    I2C_SCL_LAT = 0; I2C_SDA_LAT = 0;
    I2C_SCL_DIR = 1; I2C_SDA_DIR = 1; 
}

void I2C_Start(void) {
    I2C_SDA_DIR = 0; __delay_us(20);
    I2C_SCL_DIR = 0; __delay_us(20);
}

void I2C_Stop(void) {
    I2C_SDA_DIR = 0; __delay_us(20);
    I2C_SCL_DIR = 1; __delay_us(20);
    I2C_SDA_DIR = 1; __delay_us(20);
}

void I2C_Write(uint8_t data) {
    for (uint8_t i = 0; i < 8; i++) {
        if (data & 0x80) I2C_SDA_DIR = 1; else I2C_SDA_DIR = 0;
        __delay_us(10);
        I2C_SCL_DIR = 1; __delay_us(10);
        I2C_SCL_DIR = 0; __delay_us(10);
        data <<= 1;
    }
    I2C_SDA_DIR = 1; __delay_us(10); 
    I2C_SCL_DIR = 1; __delay_us(10); 
    I2C_SCL_DIR = 0; __delay_us(10);
}

void LCD_Send_Nibble(uint8_t i2c_addr, uint8_t data, uint8_t rs) {
    uint8_t pcf_data = data | rs | 0x08; 
    I2C_Start();
    I2C_Write(i2c_addr << 1); 
    I2C_Write(pcf_data);         // Prépare les données, EN=0
    I2C_Write(pcf_data | 0x04);  // EN=1
    __delay_us(10);              
    I2C_Write(pcf_data);         // EN=0 (L'écran lit la lettre ici)
    I2C_Stop();
    __delay_us(50); 
}

void LCD_Command(uint8_t i2c_addr, uint8_t cmd) {
    LCD_Send_Nibble(i2c_addr, cmd & 0xF0, 0);         
    LCD_Send_Nibble(i2c_addr, (cmd << 4) & 0xF0, 0);  
    __delay_ms(2); 
}

void LCD_Char(uint8_t i2c_addr, char data) {
    LCD_Send_Nibble(i2c_addr, data & 0xF0, 1);
    LCD_Send_Nibble(i2c_addr, (data << 4) & 0xF0, 1);
    __delay_us(100);
}

void LCD_String(uint8_t i2c_addr, const char *str) {
    while (*str) {
        LCD_Char(i2c_addr, *str++);
    }
}

void LCD_Init(uint8_t i2c_addr) {
    __delay_ms(50); 
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(5);
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(1);
    LCD_Send_Nibble(i2c_addr, 0x30, 0); __delay_ms(1);
    LCD_Send_Nibble(i2c_addr, 0x20, 0); __delay_ms(1); 
    LCD_Command(i2c_addr, 0x28); __delay_ms(1); 
    LCD_Command(i2c_addr, 0x08); __delay_ms(1); 
    LCD_Command(i2c_addr, 0x01); __delay_ms(5); 
    LCD_Command(i2c_addr, 0x06); __delay_ms(1); 
    LCD_Command(i2c_addr, 0x0C); __delay_ms(1); 
}

void LCD_SetCursor(uint8_t i2c_addr, uint8_t row, uint8_t col) {
    uint8_t address;
    if (row == 1) address = 0x80 + col - 1;
    else          address = 0xC0 + col - 1;
    LCD_Command(i2c_addr, address);
}

void LCD_Clear(uint8_t i2c_addr) {
    LCD_Command(i2c_addr, 0x01);
    __delay_ms(2);
}