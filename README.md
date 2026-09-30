# Minos — moderacja postów dla Discourse

Wtyczka do samodzielnie hostowanego Discourse, która wstrzymuje nowe posty, wysyła je do
oceny bramie Wergiliusz i stosuje werdykt, który brama odsyła podpisanym webhookiem:
publikuje post, publikuje go z zamaskowanymi fragmentami, odrzuca go albo zostawia
moderatorom — zgodnie z ustawieniami administratora forum. Jest częścią projektu Minos;
licencja GPL-2.0 (plik `LICENSE`).

> Trasa B2B bramy nie jest jeszcze otwarta produkcyjnie. Do tego czasu wtyczkę można
> uruchomić z bramą testową (atrapą) z repozytorium `minos-moderation/client-php` — patrz
> `docs/development.md`.

## Jak to działa

1. Użytkownik publikuje nowy temat albo odpowiedź. Wtyczka zatrzymuje post w **kolejce
   przeglądu** Discourse (jako „Czeka na ocenę Minos — moderacja postów”), a autor widzi
   zwykły komunikat, że jego post czeka na zatwierdzenie.
2. W tle wtyczka wysyła tekst posta do bramy (`POST /api/v1/b2b/oceny`). Brama od razu
   potwierdza przyjęcie.
3. Werdykt przychodzi później — zwykle po kilku sekundach, najpóźniej po około 15
   minutach — jako podpisane żądanie na adres webhooka forum:
   `https://ADRES-TWOJEGO-FORUM/minos/webhook`. Wtyczka sprawdza podpis, zanim cokolwiek
   odczyta; dostawa z błędnym albo starym podpisem jest odrzucana.
4. Wtyczka stosuje werdykt:

   | Werdykt | Co się dzieje |
   |---|---|
   | `bezpieczne` | post zostaje opublikowany |
   | `ocenzurowane` | post zostaje opublikowany z fragmentami zamaskowanymi znakiem `█` albo czeka na moderatora — ustawienie `minos_censored_action` |
   | `zablokowane` | post czeka na moderatora albo zostaje odrzucony — ustawienie `minos_blocked_action` |
   | `nieocenione` | brama nie oceniła posta: decyduje ustawienie `minos_failure_mode` |
   | brak werdyktu w czasie `minos_timeout_minutes` | jak `nieocenione` |

5. Każda decyzja zostawia **notatkę dla moderatorów** w zgłoszeniu w kolejce przeglądu:
   werdykt, kategorie (np. `wulgaryzmy`, `nekanie`) i to, co wtyczka zrobiła.

Kilka zasad, które zawsze obowiązują:

- **Wtyczka nigdy nie zgaduje werdyktu.** Wartość, której nie zna, traktuje jak
  `nieocenione`.
- **Sygnał wsparcia.** Gdy brama uzna, że treść może świadczyć o kryzysie autora
  (samookaleczenie), moderatorzy dostają o tym notatkę. Taki post nigdy nie jest
  odrzucany automatycznie — o tym decyduje człowiek.
- **Reguły forum mają pierwszeństwo.** Post, który Discourse i tak wstrzymałby sam (np.
  od nowego użytkownika, ze słowem z listy obserwowanych słów, w kategorii wymagającej
  zatwierdzenia), czeka na moderatora jak zawsze; werdykt Minos jest wtedy tylko
  podpowiedzią w notatce.
- **Zmiana w kolejce.** Jeśli moderator zmieni treść posta w kolejce, zanim przyjdzie
  werdykt, werdykt dotyczy już innego tekstu — post czeka na decyzję moderatora.
- **Maskowanie tylko pewne.** Jeśli zamaskowanych fragmentów nie da się bezpiecznie
  nanieść na treść w Markdownie, post nie jest publikowany, tylko czeka na moderatora.
- Moderator może w każdej chwili sam zatwierdzić albo odrzucić post w kolejce; późniejszy
  werdykt zostanie wtedy pominięty.

Nie są wstrzymywane: posty moderatorów i administratorów (ustawienie `minos_skip_staff`),
posty botów i systemu oraz **wiadomości prywatne** (Discourse nigdy ich nie kolejkuje, a
ich treść jest prywatna). Wtyczka nie ocenia **edycji** już opublikowanych postów.

## Instalacja

Potrzebny jest Discourse w wersji bieżącej (gałąź `latest`/`tests-passed`, tak jak jest
testowana wtyczka) oraz forum dostępne publicznie przez **HTTPS we własnej domenie**:
brama doręcza werdykty tylko po `https`, tylko na adres publiczny i nie podąża za
przekierowaniami.

1. Dopisz wtyczkę do pliku `containers/app.yml` (zwykle `/var/discourse/containers/app.yml`),
   w sekcji `hooks` → `after_code`:

   ```yaml
   hooks:
     after_code:
       - exec:
           cd: $home/plugins
           cmd:
             - git clone https://github.com/discourse/docker_manager.git
             - git clone https://github.com/minos-moderation/plugin-discourse.git minos-moderation
   ```

2. Przebuduj kontener:

   ```bash
   cd /var/discourse
   ./launcher rebuild app
   ```

3. Poproś operatora bramy o klucz B2B dla forum i podaj mu adres webhooka:
   `https://ADRES-TWOJEGO-FORUM/minos/webhook` (jeśli forum działa w podkatalogu, adres go
   zawiera — opis ustawienia `minos_enabled` pokazuje go dokładnie). Operator poda
   **klucz** (zaczyna się od `wgb2b_`) i jednorazowo **sekret webhooka**.
4. W panelu administratora: **Ustawienia → Wtyczki**, filtr `minos`. Wpisz klucz i sekret,
   wybierz profil i zachowanie, na końcu włącz `minos_enabled`.
5. Sprawdź **pulpit administratora**: jeśli czegoś brakuje albo brama odrzuca konfigurację
   (np. zły klucz, profil spoza listy klucza), zobaczysz tam komunikat z kodem błędu.

## Ustawienia

| Ustawienie | Domyślnie | Znaczenie |
|---|---|---|
| `minos_enabled` | wyłączone | Włącza moderację nowych postów. |
| `minos_gateway_url` | `https://gateway.wergiliusz.app` | Adres bramy. Wymagany `https`; zwykłe `http` działa tylko z atrapą bramy na tym samym komputerze (`localhost`). |
| `minos_api_key` | puste | Klucz forum (nagłówek `X-Gateway-Key`). Pole tajne: nie trafia do logów ani na strony. |
| `minos_webhook_secret` | puste | Sekret, którym brama podpisuje dostawy. Bez niego żaden werdykt nie zostanie przyjęty. Pole tajne. |
| `minos_profile` | `forum_adult` | Profil oceny: `forum_adult` (forum dla dorosłych) albo `forum_teen` (forum dla nastolatków). Musi być na liście profili klucza. |
| `minos_failure_mode` | `fail-closed` | Co zrobić z postem bez oceny: `fail-open` — opublikować, `fail-closed` — zostawić moderatorom. |
| `minos_timeout_minutes` | `20` | Po ilu minutach bez werdyktu post jest traktowany jak nieoceniony. Najmniej 16: brama próbuje doręczać werdykt przez 15 minut. |
| `minos_censored_action` | `publikuj_ocenzurowany` | Werdykt `ocenzurowane`: `publikuj_ocenzurowany` albo `zostaw_moderatorom`. |
| `minos_blocked_action` | `zostaw_moderatorom` | Werdykt `zablokowane`: `zostaw_moderatorom` albo `odrzuc`. |
| `minos_skip_staff` | włączone | Posty moderatorów i administratorów publikowane od razu, bez oceny. |

## `fail-open` czy `fail-closed`

Brama może nie ocenić posta: odpowiedź `nieocenione`, brak werdyktu w czasie
`minos_timeout_minutes`, błąd konfiguracji (np. nieważny klucz) albo post bez żadnego
tekstu. O tym, co wtedy, decyduje `minos_failure_mode`:

- **`fail-closed`** (domyślnie) — post czeka w kolejce przeglądu na moderatora, z notatką,
  dlaczego nie został oceniony. Nic nieocenionego nie trafia na forum samo, ale przy
  dłuższej awarii kolejka rośnie.
- **`fail-open`** — post zostaje opublikowany bez oceny (z notatką w historii zgłoszenia).
  Forum działa płynnie, ale w czasie awarii nic nie jest moderowane.

To samo ustawienie decyduje o postach dłuższych niż 3000 znaków: brama ocenia tylko ich
początek, więc przy `fail-closed` taki post (jeśli nie został zablokowany) czeka na
moderatora, a przy `fail-open` jest publikowany według werdyktu dla początku.

Chwilowe przeciążenie bramy (odpowiedzi 429 i 503) nie jest awarią: wtyczka ponawia
wysyłkę po czasie, który poda brama, a bez niego po 1, 2, 4… minutach.

Wyłączenie wtyczki niczego nie publikuje ani nie usuwa: wstrzymane posty zostają w
kolejce przeglądu dla moderatorów.

## Co wtyczka wysyła, a czego nigdy

Do bramy trafia, dla każdego wstrzymanego posta:

- **identyfikator** `discourse:<numer zgłoszenia w kolejce>` — bez żadnej treści;
- **tekst**: tytuł nowego tematu (jeśli to nowy temat), pusty wiersz i treść posta.
  Z Markdownu usuwane są tylko znaczniki (np. `**`, `[quote]`, składnia linków i
  obrazków), a zostaje każde słowo, które czytelnik może zobaczyć — także w cytatach,
  spoilerach i podsumowaniach sekcji zwijanych, żeby nie dało się niczego w nich ukryć.
  Wysyłane jest **pierwsze 3000 znaków** (limit bramy);
- **profil** z ustawienia `minos_profile`;
- **dwa sygnały antyspamowe**: liczba linków w poście i to, czy to pierwszy post autora.

Wtyczka **nigdy** nie wysyła adresu e-mail, adresu IP, identyfikatora ani nazwy
użytkownika, ani wiadomości prywatnych. Klucz trafia wyłącznie do nagłówka żądania do
bramy; ani klucz, ani sekret nie są zapisywane w logach ani pokazywane na stronach. W
logach Discourse wtyczka zapisuje tylko numer zgłoszenia, status HTTP i kod błędu bramy.

Stan każdego wstrzymanego posta (czasy, próby, werdykt bez zamaskowanego tekstu, a po
opublikowaniu z maskowaniem także oryginalna treść) wtyczka trzyma w bazie forum i usuwa
po 30 dniach. Oryginalna treść posta opublikowanego z maskowaniem zostaje też dla
moderatorów w historii zgłoszenia.

## Dla programistów

Budowa wtyczki, testy i praca z atrapą bramy: [`docs/development.md`](docs/development.md)
(po angielsku). Kontrakt bramy: `docs/contract.md` w repozytorium
`minos-moderation/client-php`.
