# Dokumentacja Skryptu Wdrożeniowego `deploy.sh`

Ten dokument opisuje działanie skryptu `deploy.sh`, który służy do automatycznego wdrażania aplikacji `simple-tor-chat` na serwerze Ubuntu. Skrypt zajmuje się instalacją niezbędnych zależności systemowych, konfiguracją Node.js, Tor, Nginx oraz uruchomieniem aplikacji.

## Działanie Skryptu

Skrypt `deploy.sh` wykonuje następujące kroki:

1.  **Aktualizacja Systemu**: Aktualizuje listę pakietów i zainstalowane oprogramowanie systemowe (`apt update && apt upgrade`).
2.  **Instalacja Nginx, Git i Tor**: Instaluje serwer Nginx (do obsługi domeny), Git (do klonowania repozytorium) oraz Tor (do stworzenia usługi Onion).
3.  **Instalacja Node.js (przez NVM)**: Instaluje Node Version Manager (NVM), a następnie najnowszą wersję LTS Node.js. Aplikacja Node.js będzie uruchamiana przez użytkownika, który uruchomił skrypt.
4.  **Konfiguracja Tor**: Konfiguruje usługę Tor Onion Service. **Ważne**: Usługa Tor jest konfigurowana tak, aby wskazywała bezpośrednio na **Serwer Czatu** (port 3000), a nie na serwer informacyjny. Skrypt wyświetla wygenerowany adres `.onion`.
5.  **Klonowanie Repozytorium**: Klonuje lub aktualizuje kod źródłowy aplikacji z GitHub do katalogu `/var/www/chat`. Zmienia również właściciela plików na użytkownika, który uruchomił skrypt.
6.  **Konfiguracja Aplikacji**: Przechodzi do katalogu aplikacji, instaluje zależności Node.js (`npm install`) i tworzy plik `.env` z konfiguracją portów, linku Onion i kluczy administratora.
7.  **Uruchomienie Aplikacji z PM2**: Instaluje PM2 (menedżer procesów Node.js) globalnie, a następnie uruchamia aplikację `server.js` za pomocą PM2. Konfiguruje również PM2 do automatycznego startu wraz z systemem.
8.  **Konfiguracja Nginx (Opcjonalnie)**: Jeśli podano domenę, skrypt konfiguruje Nginx jako reverse proxy, przekierowując ruch z domeny na **Serwer Informacyjny** (port 3330).
9.  **Konfiguracja Zapory Sieciowej (UFW)**: Konfiguruje zaporę sieciową, zezwalając na ruch Nginx (HTTP/HTTPS) oraz SSH.
10. **Konfiguracja SSL z Certbot (Opcjonalnie)**: Jeśli podano domenę, skrypt instaluje Certbot i konfiguruje darmowy certyfikat SSL od Let's Encrypt dla podanej domeny.

## Parametry Skryptu (Flagi)

Skrypt `deploy.sh` akceptuje następujące opcjonalne flagi:

*   `-c CHAT_PORT`: Określa port, na którym będzie działał serwer czatu.
    *   Domyślna wartość: `3000`
*   `-i INFO_PORT`: Określa port, na którym będzie działał serwer informacyjny.
    *   Domyślna wartość: `3330`
*   `-d DOMAIN`: Określa domenę, dla której zostanie skonfigurowany Nginx i Certbot. Jest to parametr opcjonalny.
    *   Domyślna wartość: Brak (Nginx i Certbot nie zostaną skonfigurowane, jeśli flaga nie zostanie użyta).
*   `-a ADMIN_KEYS`: Określa klucze administratora, oddzielone przecinkami, używane do usuwania wiadomości w aplikacji czatu.
    *   Domyślna wartość: `sekretnyKlucz1,innySekretnyKlucz`

### Przykład Użycia:

```bash
./deploy.sh -c 4000 -i 4001 -d mychat.example.com -a "adminKey1,adminKey2"
```