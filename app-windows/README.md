# Orecchino voor Windows

Deze Windows-port is gebaseerd op de macOS-app van Isaac Bentley. De app toont Remote ID-meldingen die een Orecchino-ontvanger via USB doorstuurt. Je kunt de interface ook uitproberen zonder ontvanger met **Simulatie**.

## Starten

1. Pak `Orecchino-volledig-project-Windows-x64.zip` uit op een Windows 10- of Windows 11-pc met een 64-bits Intel- of AMD-processor. Bouw de app via **Zelf bouwen** als je een GitHub-checkout gebruikt.
2. Open `app-windows/Orecchino.exe`. Installeer de **Evergreen Runtime** als de app om Microsoft Edge WebView2 vraagt. [WebView2 downloaden bij Microsoft](https://developer.microsoft.com/microsoft-edge/webview2/)
3. Sluit de ESP32-ontvanger aan met een USB-datakabel. De verbindingsstatus geeft aan wanneer gegevens binnenkomen.

Gebruik **Instellingen → USB-ontvanger** om zo nodig zelf een COM-poort te kiezen. Je vindt het COM-nummer in Windows Apparaatbeheer onder **Poorten (COM & LPT)**. Sluit een eventuele seriële monitor voordat je de poort opent. Als Windows geen COM-poort toont, controleer de USB-datakabel en de eventuele USB-seriële driver van je bord.

## Functies

- **Live** toont droneposities, bewegingssporen, opgegeven operatorposities en technische gegevens. De app herkent de ontvanger op een COM-poort, probeert bij onderbrekingen opnieuw verbinding te maken en zet de klok van de ontvanger.
- Stel bij **Ontvangerlocatie** de coördinaten handmatig in of neem het kaartmidden over. De app geeft die positie aan de ontvanger door en gebruikt ze voor afstanden en luchtverkeersbewaking.
- **Logboek** leest het detectielogboek van de ontvanger. Je kunt het als CSV exporteren of na bevestiging op de ontvanger wissen.
- **Offline kaarten** plant de kaarttegels voor compatibele ontvangers zoals de SenseCAP en de T5. Kies een locatie en straal, controleer het plan en klik op **Versturen** om de tegels te downloaden en naar de ontvanger te sturen. De planner houdt 1 MiB opslag vrij.
- **ADS-B** toont waarschuwingen voor mogelijke conflicten tussen ontvangen drones en bemand luchtverkeer. De standaardbron is adsb.lol. Het Windows-systeemvak toont het aantal actuele contacten en geeft bij conflicten een Windows-melding als je meldingsinstellingen dat toelaten.
- De **FAA-laag** toont tijdelijke beperkingen uit de Verenigde Staten. De kaartachtergrond, ADS-B, de FAA-laag en het downloaden van offline kaarttegels hebben internet nodig.
- De **Droneguide-laag** toont Belgische geozones die het luchtruim tot en met **500 ft boven de grond** (AGL, 152,4 m) raken. Je kunt de laag naast de FAA-laag aan- en uitzetten. Open een zone om de beschikbare hoogte-, beperkings- en tijdgegevens te bekijken.
- De **ATAK-uitvoer** deelt live dronedetecties met een geldige positie als kaartmarkeringen via Cursor on Target (CoT) over UDP.

## Detecties naar ATAK sturen

1. Verbind de Windows-pc en het ATAK-toestel met hetzelfde bereikbare netwerk. Gebruik het netwerkadres van het ATAK-toestel als bestemming.
2. Controleer in ATAK onder **Settings → Network Preferences → Network Connection Preferences → Input/Output Management → Manage Inputs** of **Enable Mesh Network Mode** en de UDP-ingang op poort **4242** aanstaan. Gebruik de ingestelde poort als die afwijkt. [ATAK-CIV-netwerkbroncode](https://github.com/TAK-Product-Center/atak-civ/blob/main/atak/ATAK/app/src/main/java/com/atakmap/comms/CotService.java#L745-L762)
3. Open **Instellingen → ATAK** in Orecchino, vul het adres en de UDP-poort in en schakel de uitvoer in. Sla de instellingen op.

De uitvoer deelt de dronepositie, de kaartnaam en indien beschikbaar de hoogte boven de WGS 84-ellipsoïde. De verzendstatus geeft aan wanneer Orecchino een bericht lokaal aan UDP heeft aangeboden. Controleer de kaart in ATAK om de ontvangst te zien.

## Belgische geozones laden

Ga naar **Instellingen → Belgische geozones**. Schakel **Automatisch ophalen** in als je toestemming hebt voor toegang tot de Droneguide-API. Orecchino haalt dan de Belgische geozones op bij skeyes en ververst de laag elke 15 minuten. Met **Nu vernieuwen** start je zelf een nieuwe aanvraag. **Zoom naar geozones** brengt de geladen laag in beeld. [Droneguide WFS](https://map.droneguide.be/ows?service=WFS&version=2.0.0&request=GetCapabilities) · [Droneguide-gebruiksvoorwaarden](https://map.droneguide.be/api/licenseagreements/current)

Een zone telt mee zodra haar hoogtebereik het luchtruim tussen de grond en 500 ft AGL overlapt. Voor de selectie gebruikt de app grenzen in AGL en de AGL-omrekening die skeyes aanlevert. De instellingen vermelden hoeveel zones door een onbepaalde AGL-hoogte buiten de selectie vallen. Dit geldt ook voor geïmporteerde gegevens.

Gebruik **Alleen actief** onder **Instellingen → Belgische geozones** om binnen die hoogteselectie enkel zones met een bevestigde activiteitsstatus te tonen. De schakelaar wordt onthouden. Bij online gegevens vermeldt de app het opnametijdstip. Na een mislukte vernieuwing of zodra de opname 30 minuten oud is, geldt de activiteitsstatus als onbekend. Voor geïmporteerde zones gebruikt de app expliciete geldigheidsperiodes en ondersteunde tijdschema’s met tijdzone.

Bij een mislukte vernieuwing toont de app de laatst ingelezen gegevens en vermeldt ze de fout. Activiteit uit de API geldt voor het weergegeven tijdstip van opname. Raadpleeg Droneguide en de actuele NOTAM voor de actuele activiteit en toegangsvoorwaarden. [Droneguide (skeyes)](https://map.droneguide.be/) · [AIM-Meteo Briefing](https://ops.skeyes.be/)

Je kunt ook een bestand gebruiken.

1. Download een geozonebestand in JSON-formaat via Droneguide. [Droneguide (skeyes)](https://map.droneguide.be/) · [Informatie van de FOD Mobiliteit](https://mobilit.belgium.be/nl/file/11722/download?token=ssQBAwSw)
2. Open **Instellingen → Belgische geozones** in Orecchino. Kies het ED-269 JSON- of GeoJSON-bestand en klik op **Geozones importeren**.
3. Klik op **Zoom naar geozones** om de laag in beeld te brengen. Een succesvolle import vervangt de vorige lokale export en schakelt automatisch ophalen uit.

## Zelf bouwen

Open PowerShell in de map `app-windows` en gebruik Go 1.25 of hoger. De Go-afhankelijkheden voor de build zijn meegeleverd in `vendor`.

```powershell
go test -mod=vendor ./...
go build -mod=vendor -trimpath -ldflags '-H windowsgui' -o Orecchino.exe .
```

Voer `go run -mod=vendor . -preview -demo` uit om de interface met simulatiegegevens in een browser te openen. Open het lokale adres dat in de terminal verschijnt. De Windows-versie bewaart instellingen en appgegevens onder `%LOCALAPPDATA%\Orecchino`.

De Windows-build is vanuit Linux gecompileerd. De controle van het Windows-venster met WebView2 en de USB-verbinding met een fysieke ontvanger vereist een Windows-pc en de hardware.

Het Windows-pictogram en manifest in `resources` zijn al opgenomen in `resources_windows_amd64.syso`. Als je die bestanden aanpast, maak je het resourcebestand opnieuw met `rsrc` v0.10.2 en `rsrc -arch amd64 -ico resources/Orecchino.ico -manifest resources/orecchino.manifest -o resources_windows_amd64.syso`.

## Licentie en bron

Orecchino is vrije software onder de GNU General Public License, versie 3 of later. `LICENSE` bevat de volledige licentie. De map `app-windows` bevat de broncode van deze Windows-port en de licentiegegevens voor de meegeleverde afhankelijkheden. [Componenten van derden](licenties/THIRD_PARTY.md)

De Windows-port van 18 november 2026 vervangt de macOS-interface en seriële integratie door een Windows-desktopvenster met WebView2 en ondersteuning voor COM-poorten. [Originele macOS-broncode op de gebruikte commit `a3d0620`](https://github.com/isaacbentley/orecchino-esp32/tree/a3d06206010e66d5295ad36e167e100d2c0670c6/app)
