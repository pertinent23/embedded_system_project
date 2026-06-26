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
    info_mode: 2
};

// ==========================================
// API POUR LE MODULE WIFI (ESP-01S)
// ==========================================
// Le PIC assemble la requête : GET /api/update?hum=45
app.get('/api/update', async (req, res) => {
    if (req.query.hum !== undefined) {
        const hum = parseInt(req.query.hum);
        if (!isNaN(hum)) {
            // Sauvegarde dans MongoDB Atlas
            await new HumidityLog({ value: hum }).save();
            console.log(`[PIC] Humidité reçue: ${hum}%`);
            
            // --- LIMITATION À 2000 ENREGISTREMENTS ---
            // On compte le nombre total et on supprime le plus ancien s'il y en a trop
            const count = await HumidityLog.countDocuments();
            if (count > 2000) {
                await HumidityLog.findOneAndDelete({}, { sort: { timestamp: 1 } });
            }
        }

        // Formate la réponse exactement comme attendue par l'assembleur
        // Ex: "CMD:2,2,2"
        const cmdResponse = `CMD:${systemState.sys_off},${systemState.manual_pump},${systemState.info_mode}`;
        res.send(cmdResponse);
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
        systemState[name] = value;
        console.log(`[WEB] Bouton ${name} défini sur ${value}`);
        res.json({ success: true, state: systemState });
    } else {
        res.status(400).json({ error: 'Bouton ou valeur invalide' });
    }
});

// ==========================================
// DEMARRAGE DU SERVEUR
// ==========================================
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`🚀 Serveur Node.js démarré sur http://localhost:${PORT}`);
});
