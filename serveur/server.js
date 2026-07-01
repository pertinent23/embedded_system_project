const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const path = require('path');
require('dotenv').config();

const app = express();
app.use(express.json());
app.use(cors());

// ==========================================
// CONFIGURATION MONGODB ATLAS
// ==========================================
const PORT = process.env.PORT || 3000;
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017/smartwatering';

console.log(process.env.MONGO_URI)
mongoose.connect(MONGO_URI)
    .then(() => {
        console.log('✅ Connecté à MongoDB (Atlas)');
        // On ne démarre le serveur que si la BDD est connectée
        app.listen(PORT, () => {
            console.log(`🚀 Serveur Node.js démarré sur http://localhost:${PORT}`);
        });
    })
    .catch(err => {
        console.error('❌ Erreur critique : Impossible de se connecter à MongoDB');
        console.error(err.message);
        process.exit(1); // Arrête le script proprement car il ne peut pas fonctionner sans BDD
    });

// Schéma de données pour l'historique d'humidité
const humiditySchema = new mongoose.Schema({
    value: Number,
    timestamp: { type: Date, default: Date.now, index: true } // Index ajouté pour des tris hyper rapides
});
const HumidityLog = mongoose.model('HumidityLog', humiditySchema);

// ==========================================
// ETAT DU SYSTEME (Priorités Réseau)
// ==========================================
// 0 = Actif (Appuyé), 1 = Inactif (Relâché), 2 = Mode Physique (Laisser faire le PIC)
let systemState = {
    sys_off: 2,
    manual_pump: 2,
    info_mode: 2,
    led_green: 0,
    led_red: 1,
    pump: 0,
    poll_interval: 2, // En secondes (par défaut 2)
    humidity: 0,
    last_sync_time: "--:--",
    last_sync_date: "--/--",
    last_sync_temp: "--"
};

// ==========================================
// API POUR LE MODULE WIFI (ESP-01S)
// ==========================================
// Le PIC assemble la requête : GET /api/update?hum=45&led_green=1&led_red=0&pump=1
app.get('/api/update', async (req, res) => {
    if (req.query.hum !== undefined) {
        const hum = parseInt(req.query.hum);
        if (!isNaN(hum)) {
            systemState.humidity = hum;
            // Sauvegarde dans MongoDB Atlas
            await new HumidityLog({ value: hum }).save();
            console.log(`[PIC] Humidité reçue: ${hum}%`);
            
            // --- LIMITATION À 2000 ENREGISTREMENTS ---
            const count = await HumidityLog.countDocuments();
            if (count > 2000) {
                await HumidityLog.findOneAndDelete({}, { sort: { timestamp: 1 } });
            }
        }

        // Enregistre les états renvoyés par le PIC
        if (req.query.led_green !== undefined) {
            systemState.led_green = parseInt(req.query.led_green);
        }
        if (req.query.led_red !== undefined) {
            systemState.led_red = parseInt(req.query.led_red);
        }
        if (req.query.pump !== undefined) {
            systemState.pump = parseInt(req.query.pump);
        }

        // Évaluation des boutons physiques du PIC (0 = appuyé, 1 = relâché)
        const pb0 = req.query.pb0 !== undefined ? parseInt(req.query.pb0) : 1;
        const pb1 = req.query.pb1 !== undefined ? parseInt(req.query.pb1) : 1;
        const pb2 = req.query.pb2 !== undefined ? parseInt(req.query.pb2) : 1;

        // Bouton 0 : System Off (0 = ON, 1 = OFF, 2 = Physique Local)
        if (pb0 === 0) {
            systemState.sys_off = 2; // Physique Local (Prioritaire)
        } else {
            // Si le bouton était en physique local et est relâché, par défaut il est forcé à OFF (1)
            if (systemState.sys_off === 2) {
                systemState.sys_off = 1;
            }
        }

        // Bouton 1 : Manual Pump
        if (pb1 === 0) {
            systemState.manual_pump = 2; // Physique Local (Prioritaire)
        } else {
            if (systemState.manual_pump === 2) {
                systemState.manual_pump = 1;
            }
        }

        // Bouton 2 : Info Mode
        if (pb2 === 0) {
            systemState.info_mode = 2; // Physique Local (Prioritaire)
        } else {
            if (systemState.info_mode === 2) {
                systemState.info_mode = 1;
            }
        }

        // Récupère l'heure de Paris
        const now = new Date();
        const options = { timeZone: 'Europe/Paris', hour: '2-digit', minute: '2-digit', day: '2-digit', month: '2-digit' };
        const formatter = new Intl.DateTimeFormat('fr-FR', options);
        const parts = formatter.formatToParts(now);
        
        let day = '01', month = '01', hour = '12', minute = '00';
        parts.forEach(p => {
            if (p.type === 'day') day = p.value;
            if (p.type === 'month') month = p.value;
            if (p.type === 'hour') hour = p.value;
            if (p.type === 'minute') minute = p.value;
        });

        // Température fictive simulée
        const temp = "24";

        systemState.last_sync_time = `${hour}:${minute}`;
        systemState.last_sync_date = `${day}/${month}`;
        systemState.last_sync_temp = temp;

        // Formate la réponse fixe : C:s,m,i,pp|T:tt|D:DD/MM|H:HH:MM
        // pp est l'intervalle de polling sur 2 caractères
        const pp = String(systemState.poll_interval).padStart(2, '0');
        const responseStr = `C:${systemState.sys_off},${systemState.manual_pump},${systemState.info_mode},${pp}|T:${temp}|D:${day}/${month}|H:${hour}:${minute}`;
        
        console.log(`[PIC] Envoi réponse : ${responseStr}`);
        res.send(responseStr);
    } else {
        res.status(400).send("Erreur: Paramètre hum manquant");
    }
});

// Sert les fichiers statiques (images, CSS, index.html) uniquement si aucune route API n'a matché
app.use(express.static('public'));

// ==========================================
// API POUR LA PAGE WEB (DASHBOARD)
// ==========================================

// Obtenir l'historique pour le graphique
app.get('/api/data', async (req, res) => {
    try {
        const logs = await HumidityLog.find().sort({ timestamp: -1 }).limit(50);
        res.json(logs.reverse());
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Obtenir l'état actuel des boutons
app.get('/api/state', (req, res) => {
    res.json(systemState);
});

// Forcer l'état d'un bouton depuis l'interface Web
app.post('/api/button/:name', (req, res) => {
    const name = req.params.name;
    const value = parseInt(req.body.value);

    if (systemState.hasOwnProperty(name) && [0, 1, 2].includes(value)) {
        // Priorité physique : si le bouton est physiquement appuyé (état = 2), on ne peut pas le forcer en ligne (sauf si on demande l'état physique)
        if (systemState[name] === 2 && value !== 2) {
            return res.status(400).json({ error: 'Priorité physique active : impossible de forcer en ligne.' });
        }
        systemState[name] = value;
        console.log(`[WEB] Bouton ${name} défini sur ${value}`);
        res.json({ success: true, state: systemState });
    } else {
        res.status(400).json({ error: 'Bouton ou valeur invalide' });
    }
});

// Forcer la fréquence de polling depuis l'interface Web
app.post('/api/polling-rate', (req, res) => {
    const rate = parseInt(req.body.rate);
    if (!isNaN(rate) && rate >= 1) {
        systemState.poll_interval = rate;
        console.log(`[WEB] Fréquence de polling du PIC définie à ${rate}s`);
        res.json({ success: true, state: systemState });
    } else {
        res.status(400).json({ error: 'Fréquence invalide' });
    }
});

// Pas de double app.listen pour éviter l'erreur EADDRINUSE

