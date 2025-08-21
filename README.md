# Dokumentacja Aplikacji i Konfiguracji Nginx

**Szczegółowe instrukcje dotyczące instalacji i wdrożenia znajdują się w pliku [INSTALL.md](INSTALL.md).**

## 1. Aplikacja Node.js (`very-simple-chat`)

Aplikacja jest prostym czatem opartym na Node.js, zaprojektowanym z myślą o prostocie i minimalizmie. Składa się z dwóch głównych komponentów serwerowych.

### Architektura

Aplikacja uruchamia dwa oddzielne serwery HTTP:

1.  **Serwer Informacyjny (Info Server)**:
    *   **Port**: `3330` (konfigurowalny w pliku `.env` przez `INFO_PORT`).
    *   **Cel**: Jest to punkt wejścia dla Nginx. Serwuje statyczną stronę `info.html`, która ma za zadanie wyświetlić link do właściwego czatu (prawdopodobnie w sieci Tor).
    *   **Logika**: Odczytuje plik `public/info.html`, wstawia w nim link zdefiniowany w zmiennej środowiskowej `ONION_LINK` i serwuje go użytkownikowi.

2.  **Serwer Czatu (Chat Server)**:
    *   **Port**: `3000` (konfigurowalny w pliku `.env` przez `CHAT_PORT`).
    *   **Cel**: Obsługuje główną funkcjonalność czatu.
    *   **Technologie**:
        *   `express`: Do serwowania plików statycznych (`private/index.html`) i obsługi endpointów API.
        *   `ws`: Do komunikacji w czasie rzeczywistym (WebSocket) między klientami.
        *   `sqlite3`: Jako baza danych do przechowywania wiadomości. Plik bazy danych to `database.sqlite`.
        *   `dotenv`: Do zarządzania zmiennymi środowiskowymi.

### Baza Danych

Aplikacja używa bazy danych SQLite z jedną tabelą:

*   **`messages`**:
    *   `id` (INTEGER, PRIMARY KEY, AUTOINCREMENT)
    *   `timestamp` (TEXT)
    *   `nickname` (TEXT)
    *   `message` (TEXT)

### API i Funkcjonalność

*   **WebSocket**: Po nawiązaniu połączenia, serwer przesyła nowe wiadomości do wszystkich podłączonych klientów. Obsługuje również komunikaty o usunięciu wiadomości.
*   **Endpointy HTTP**:
    *   `GET /`: Serwuje główny interfejs użytkownika czatu (`private/index.html`).
    *   `GET /messages`: Zwraca historię wszystkich wiadomości z bazy danych w formacie JSON.
    *   `POST /send-message`: Przyjmuje `nick` i `message`, zapisuje je do bazy danych, a następnie rozgłasza do wszystkich klientów przez WebSocket.
    *   `POST /delete-message`: Umożliwia usunięcie wiadomości. Wymaga podania `messageId` oraz klucza administratora (`adminkey`), który jest weryfikowany z listą kluczy w zmiennej środowiskowej `ADMIN_KEYS`.

---

## 2. Konfiguracja Nginx

Nginx jest używany jako odwrotne proxy (reverse proxy) przed aplikacją Node.js.

### Plik Konfiguracyjny: `/etc/nginx/sites-enabled/onion.23.net.pl`

*   **Domena**: `onion.23.net.pl`
*   **Przekierowanie na HTTPS**: Wszystkie zapytania na porcie 80 (HTTP) są automatycznie przekierowywane na port 443 (HTTPS) z kodem 301.
*   **SSL**: Szyfrowanie jest obsługiwane przez certyfikaty Let's Encrypt. Konfiguracja SSL jest zarządzana przez `certbot`.
*   **Odwrotne Proxy**:
    *   Wszystkie przychodzące zapytania do `onion.23.net.pl` są przekazywane do serwera informacyjnego aplikacji Node.js, działającego pod adresem `http://127.0.0.1:3330`.
    *   Konfiguracja zawiera niezbędne nagłówki do obsługi **WebSockets** (`Upgrade` i `Connection`), co jest kluczowe dla działania czatu w czasie rzeczywistym, jeśli ruch do czatu również przechodziłby przez Nginx.
    *   Przekazywane są również nagłówki `X-Real-IP` i `X-Forwarded-For`, aby aplikacja mogła zidentyfikować oryginalny adres IP klienta.

---

## 3. Konfiguracja Usługi Tor Onion

Usługa Tor Onion Service jest skonfigurowana tak, aby wskazywać bezpośrednio na **Serwer Czatu** (port 3000). Dzięki temu użytkownicy sieci Tor mogą uzyskać bezpośredni dostęp do funkcji czatu, omijając serwer informacyjny.

*   **Port docelowy**: `3000` (CHAT_PORT)
*   **Dostęp**: Wyłącznie przez sieć Tor.

---

## 4. Wdrożenie i Uruchomienie

Szczegółowe instrukcje dotyczące wdrożenia (zarówno automatycznego przy użyciu skryptu `install.sh`, jak i ręcznego) znajdują się w pliku [INSTALL.md](INSTALL.md).

**Skrócona instrukcja automatyczna:**
1.  Sklonuj repozytorium.
2.  Nadaj uprawnienia do wykonania skryptu: `chmod +x install.sh`.
3.  Uruchom skrypt z `sudo`, podając obowiązkowe klucze administratora:
    ```bash
    sudo ./install.sh -a "klucz1,klucz2"
    ```