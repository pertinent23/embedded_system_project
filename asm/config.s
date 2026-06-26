; ============================================================================
; CONFIGURATION DU MICROCONTRÔLEUR
; ============================================================================
    PROCESSOR   18F47Q84
    #include    <xc.inc>

    CONFIG FEXTOSC  = OFF
    CONFIG RSTOSC   = HFINTOSC_64MHZ
    CONFIG WDTE     = OFF
    CONFIG LVP      = ON
    CONFIG MCLRE    = INTMCLR
    CONFIG MVECEN   = OFF

; ============================================================================
; VARIABLES GLOBALES ET DONNÉES
; ============================================================================
    GLOBAL seconds, minutes, hours, day, month, yearL, yearH
    GLOBAL uptime_minutesL, uptime_minutesH, raw_moistureL, raw_moistureH
    GLOBAL humidity_percent, pump_state, manual_chrono_secL, manual_chrono_secH
    GLOBAL slide_timer, current_info_slide, current_off_slide, backlight_status
    GLOBAL sleep_timeout_counter
    
    GLOBAL lcd_line1, lcd_line2
    
    ; Variables mathématiques & utilitaires
    GLOBAL math_arg1L, math_arg1H, math_arg2L, math_arg2H
    GLOBAL math_resL, math_resH, math_remL, math_remH
    GLOBAL delay_cnt1, delay_cnt2

    UDATA
seconds                 RES 1
minutes                 RES 1
hours                   RES 1
day                     RES 1
month                   RES 1
yearL                   RES 1
yearH                   RES 1
uptime_minutesL         RES 1
uptime_minutesH         RES 1
raw_moistureL           RES 1
raw_moistureH           RES 1
humidity_percent        RES 1
pump_state              RES 1
manual_chrono_secL      RES 1
manual_chrono_secH      RES 1
slide_timer             RES 1
current_info_slide      RES 1
current_off_slide       RES 1
backlight_status        RES 1
sleep_timeout_counter   RES 1

lcd_line1               RES 17
lcd_line2               RES 17

math_arg1L              RES 1
math_arg1H              RES 1
math_arg2L              RES 1
math_arg2H              RES 1
math_resL               RES 1
math_resH               RES 1
math_remL               RES 1
math_remH               RES 1

delay_cnt1              RES 1
delay_cnt2              RES 1

    END
