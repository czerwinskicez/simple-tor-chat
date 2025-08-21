# Instrukcja Wdrożenia Aplikacji

## Instalacja Automatyczna (Zalecane)

Ta metoda wykorzystuje skrypt `install.sh` do pełnej automatyzacji procesu na świeżym serwerze Ubuntu. Jest to najszybszy i najprostszy sposób na uruchomienie aplikacji.

1.  **Pobierz repozytorium:**
    ```bash
    git clone https://github.com/czerwinskicez/simple-tor-chat.git
    cd simple-tor-chat
    ```

2.  **Nadaj uprawnienia do wykonania skryptu:**
    ```bash
    chmod +x install.sh
    ```

3.  **Uruchom skrypt instalacyjny:**
    Skrypt **musi** być uruchomiony z uprawnieniami `sudo`. Należy obowiązkowo podać klucze administratora za pomocą flagi `-a`.
    ```bash
    sudo ./install.sh -a "kluczAdmina1,sekretnyKlucz2" [opcjonalne_parametry]
    ```
    *   **Parametry:** `-a` (obowiązkowe), `-d` (opcjonalne), `-c` (opcjonalne), `-i` (opcjonalne).

---

## Instalacja Ręczna (Dla zaawansowanych użytkowników)

Poniższe kroki opisują manualny proces instalacji, dając pełną kontrolę nad każdym etapem. Jest to przydatne do niestandardowych konfiguracji lub w celach edukacyjnych.

Ten przewodnik opisuje krok po kroku, jak wdrożyć aplikację czatu na nowym serwerze z systemem Ubuntu.

### Wymagania wstępne
*   Serwer z systemem Ubuntu (np. 22.04 LTS).
*   Dostęp do serwera z uprawnieniami `sudo`.
*   (Opcjonalnie) Domena skonfigurowana tak, aby wskazywała na adres IP serwera.

---

### Krok 1: Aktualizacja Systemu

Zaloguj się na serwer i zaktualizuj listę pakietów oraz zainstalowane oprogramowanie.

```bash
sudo apt update && sudo apt upgrade -y
```

### Krok 2: Instalacja Node.js (przez NVM)

Zainstalujemy Node.js przy użyciu NVM (Node Version Manager), co jest zalecaną praktyką pozwalającą na łatwe zarządzanie wersjami Node.js.

```bash
# Pobierz i uruchom skrypt instalacyjny NVM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

# Aktywuj NVM w bieżącej sesji
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Zainstaluj najnowszą wersję LTS (Long Term Support) Node.js
nvm install --lts

# Sprawdź wersje
node -v
npm -v
```

### Krok 3: Instalacja Nginx i Git

Nginx będzie pełnił rolę serwera proxy, a Git jest potrzebny do sklonowania repozytorium.

```bash
sudo apt install nginx git -y
```

### Krok 4: Instalacja i Konfiguracja Tora

Aby aplikacja była dostępna jako usługa w sieci Tor (tzw. Onion Service), musisz zainstalować i skonfigurować Tora.

1.  **Zainstaluj Tora**:
    ```bash
    sudo apt install tor -y
    ```

2.  **Skonfiguruj Onion Service**:
    Otwórz plik konfiguracyjny Tora, który znajduje się w `/etc/tor/torrc`:
    ```bash
    sudo nano /etc/tor/torrc
    ```

3.  **Dodaj poniższe linie** na końcu pliku, aby skonfigurować usługę. Serwer Node.js (czat) działa na porcie 3000, więc na ten port będziemy przekierowywać ruch.
    ```ini
    HiddenServiceDir /var/lib/tor/hidden_service/
    HiddenServicePort 80 127.0.0.1:3000
    ```

4.  **Zrestartuj Tora**, aby zmiany weszły w życie:
    ```bash
    sudo systemctl restart tor
    ```

5.  **Odczytaj adres .onion**:
    Po restarcie Tora, w katalogu `/var/lib/tor/hidden_service/` zostanie utworzony plik `hostname`, który zawiera wygenerowany adres `.onion`. Użyj poniższej komendy, aby go odczytać:
    ```bash
    sudo cat /var/lib/tor/hidden_service/hostname
    ```
    **Zapisz ten adres!** Będzie on potrzebny w kolejnych krokach konfiguracyjnych.

---

### Krok 5: Klonowanie Repozytorium Aplikacji

Sklonuj kod źródłowy aplikacji z GitHub. Możesz umieścić go w dowolnym katalogu, np. `/var/www/chat`.

```bash
sudo git clone https://github.com/czerwinskicez/simple-tor-chat.git /var/www/chat
cd /var/www/chat
```

### Krok 6: Konfiguracja i Instalacja Zależności Aplikacji

1.  **Zainstaluj zależności projektu** zdefiniowane w `package.json`:
    ```bash
    sudo npm install
    ```

2.  **Utwórz plik konfiguracyjny `.env`**:
    ```bash
    sudo nano .env
    ```

3.  **Wklej do pliku `.env` poniższą zawartość**, dostosowując wartości do swoich potrzeb:
    ```ini
    # Port dla serwera czatu (dostępny wewnętrznie)
    CHAT_PORT=3000

    # Port dla serwera informacyjnego (ten, do którego łączy się Nginx)
    INFO_PORT=3330

    # Link do Twojej usługi w sieci Tor lub zwykłej domeny czatu
    ONION_LINK=http://your-onion-service-address.onion

    # Sekretne klucze do usuwania wiadomości (oddzielone przecinkami)
    ADMIN_KEYS=sekretnyKlucz1,innySekretnyKlucz
    ```

4.  **Zmień właściciela plików**, aby aplikacja mogła być zarządzana przez Twojego użytkownika (zakładając, że jesteś zalogowany jako `ubuntu`):
    ```bash
    sudo chown -R ubuntu:ubuntu /var/www/chat
    ```
    *Jeśli uruchamiasz jako inny użytkownik, zmień `ubuntu:ubuntu` odpowiednio.*

### Krok 7: Uruchomienie Aplikacji za Pomocą PM2

PM2 to menedżer procesów dla aplikacji Node.js, który utrzymuje aplikację przy życiu i ułatwia zarządzanie.

1.  **Zainstaluj PM2 globalnie**:
    ```bash
    sudo npm install pm2 -g
    ```

2.  **Uruchom aplikację**:
    Będąc w katalogu `/var/www/chat`:
    ```bash
    pm2 start server.js --name "simple-chat"
    ```

3.  **Skonfiguruj PM2 do startu razem z systemem**:
    ```bash
    pm2 startup
    ```
    *System poprosi o wykonanie dodatkowej komendy, skopiuj ją i uruchom.*

4.  **Zapisz listę procesów**:
    ```bash
    pm2 save
    ```

### Krok 8: Konfiguracja Nginx jako Reverse Proxy

1.  **Utwórz nowy plik konfiguracyjny dla swojej domeny** w katalogu `/etc/nginx/sites-available/`:
    ```bash
    sudo nano /etc/nginx/sites-available/twojadomena.com
    ```

2.  **Wklej poniższą konfigurację**, zastępując `twojadomena.com` swoją prawdziwą domeną:
    ```nginx
    server {
        listen 80;
        server_name twojadomena.com;

        location / {
            proxy_pass http://127.0.0.1:3330; # Przekierowanie do serwera INFO
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
        }
    }
    ```

3.  **Aktywuj konfigurację**, tworząc dowiązanie symboliczne do `/etc/nginx/sites-enabled/`:
    ```bash
    sudo ln -s /etc/nginx/sites-available/twojadomena.com /etc/nginx/sites-enabled/
    ```

4.  **Przetestuj i zrestartuj Nginx** (główny plik konfiguracyjny Nginx to `/etc/nginx/nginx.conf`):
    ```bash
    sudo nginx -t
    sudo systemctl restart nginx
    ```

### Krok 9: Konfiguracja Zapory Sieciowej (UFW)

Zezwól na ruch HTTP i HTTPS oraz SSH.

```bash
sudo ufw allow 'Nginx Full'
sudo ufw allow 'OpenSSH'
sudo ufw enable
```

### Krok 10 (Opcjonalnie): Konfiguracja SSL z Certbot

Jeśli masz domenę, zabezpiecz ją darmowym certyfikatem SSL od Let's Encrypt.

1.  **Zainstaluj Certbota**:
    ```bash
    sudo apt install certbot python3-certbot-nginx -y
    ```

2.  **Uruchom Certbota dla swojej domeny** (zmodyfikuje on konfigurację Nginx w `/etc/nginx/sites-available/twojadomena.com`):
    ```bash
    sudo certbot --nginx -d twojadomena.com
    ```
    Certbot automatycznie zmodyfikuje plik konfiguracyjny Nginx, aby włączyć SSL i przekierowania.

Po wykonaniu tych kroków aplikacja powinna być dostępna pod Twoją domeną.