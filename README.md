# Bot Offerte Giochi

Pubblica in un canale Discord offerte, giochi gratis, giveaway e giochi in evidenza presi da [Allkeyshop](https://www.allkeyshop.com/blog/).
Gira da solo su GitHub ogni 15 minuti circa, anche a PC spento, e pubblica ogni gioco una volta sola.

- **Link del webhook Discord:** non va mai scritto nei file. Sta nel segreto `DISCORD_WEBHOOK_URL`
  (Settings > Secrets and variables > Actions).
- **Impostazioni:** `config-bot.json` (fonti attive, etichette, colori, quanti post per giro).
- **Giochi già pubblicati:** `stato.json`, aggiornato in automatico dal bot. Non modificarlo.
- **Mettere in pausa o riattivare:** scheda Actions > Bot Offerte Giochi > menu `...` > Disable / Enable workflow.
- **Controllare cosa ha fatto:** scheda Actions, apri un giro e guarda il passaggio "Controlla Allkeyshop e pubblica su Discord".
