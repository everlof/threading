# Threading Linux – privat alfatest

Det här paketet är avsett för Ubuntu 26.04 på Intel/AMD (x86_64). Det är en tidig Linux-preview
med projekt, terminaler och Claude/Codex-sessioner. Läs `VERIFICATION.txt` i leveransen för exakt
byggversion, genomförda kontroller och sådant som ännu behöver provas på din dator.

## Installera och starta

Kontrollera att din vanliga terminal redan kan starta den agent du vill använda, `claude` eller
`codex`, och att du är inloggad. Threading använder din lokala installation och inloggning.

Öppna en terminal i leveransens mapp:

```bash
sha256sum --check SHA256SUMS
sudo apt install ./threading-linux-preview-ubuntu24.04-amd64.deb
```

Starta **Threading Linux Preview** från appmenyn. Paketnamnets `ubuntu24.04` anger miljön som
binärerna byggdes i. Ubuntu 26.04 är testmiljön för den här leveransen. Swift och källkoden behövs inte.

Du kan också öppna ett projekt direkt:

```bash
/opt/threading-linux-preview/run-app.sh /absolut/sökväg/till/projekt
```

Om agenten saknas i appen, ange dess absoluta sökväg vid start, exempelvis:

```bash
THREADING_LINUX_CODEX="$(command -v codex)" /opt/threading-linux-preview/run-app.sh
```

## Prova i ungefär en halvtimme

1. Lägg till ett mindre projekt med `+` och **Use an Existing Folder…**.
2. Starta en terminal i projektet. Kontrollera arbetskatalog, tangentbord och kopiera/klistra in.
3. Starta en chatt med agenten du redan använder. Be om en liten kodändring och prova eventuella
   tillståndsfrågor. Kontrollera resultatet i projektet.
4. Växla mellan chatten och terminalen. Prova fler rader i meddelandet och scrolla i ett längre svar.
5. Stäng fönstret och öppna appen igen. Kontrollera att projekt och sessioner finns kvar och går att öppna.
6. Notera textstorlek, skärmskalning, menyer, svensk text och sådant som känns långsamt eller otydligt.

Att stänga fönstret lämnar pågående terminalprocesser hos bakgrundsdaemonen. Det är avsiktligt;
nästa start kan återansluta till dem.

## Om något går fel

Skriv vad du gjorde, vad du väntade dig och vad som hände. Bifoga gärna en skärmbild. Ange om du
kör Wayland eller X11 och din skärmskalning om du känner till dem. Mallen `FEEDBACK.txt` finns i leveransen.

För att fånga appens felutskrift: stäng fönstret, starta så här och försök upprepa problemet:

```bash
/opt/threading-linux-preview/run-diagnostic.py
```

Samla sedan en rapport:

```bash
/opt/threading-linux-preview/collect-diagnostics.py --include-logs --output "$HOME/Downloads"
```

Kommandot visar var rapportmappen och arkivet ligger. Granska innehållet innan du skickar arkivet
till David: loggutdrag kan innehålla projektsökvägar eller text från arbetet. Rapporten skapas lokalt
och skickas aldrig automatiskt. Utan `--include-logs` samlas enbart system- och versionsinformation.

## Begränsningar

- Managers, Threadings egna MCP-verktyg och flera av Mac-appens funktioner saknas.
- Claudes hookbaserade tillståndshantering i native-chatten är ännu ofullständig.
- Automatisk uppdatering saknas; en ny testversion installeras med samma `apt install`-kommando.
- Verkliga agentkonton, skrivbord, inmatningsmetoder och skärmskalning behöver provas praktiskt.
  Automatiserade agenttester använder kontrollerade testprocesser.

## Avinstallera

Avsluta först de agent- och terminalprocesser du startat i appen och stäng fönstret.

```bash
sudo apt remove threading-linux-preview
```

Sparad appdata ligger normalt i `~/.local/share/threading-linux-spike` och behålls vid avinstallation.
Projektens egna filer ligger kvar i sina vanliga mappar.
