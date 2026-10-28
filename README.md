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
  odrzucany ani ukrywany automatycznie — także gdy werdykt przyjdzie po publikacji w
  trybie `fail-open` — a wtyczka nie wysyła w tej sprawie żadnej wiadomości autorowi. O
  tym decyduje człowiek.
- **Reguły forum mają pierwszeństwo.** Post, który Discourse i tak wstrzymałby sam (np.
  od nowego użytkownika, ze słowem z listy obserwowanych słów, w kategorii wymagającej
  zatwierdzenia), czeka na moderatora jak zawsze; werdykt Minos jest wtedy tylko
  podpowiedzią w notatce. Dotyczy to także `fail-open`: taki post nigdy nie jest
  publikowany bez oceny.
- **Zmiana w kolejce.** Jeśli moderator zmieni treść posta w kolejce, zanim przyjdzie
  werdykt, werdykt dotyczy już innego tekstu — post czeka na decyzję moderatora.
- **Maskowanie tylko pewne.** Jeśli zamaskowanych fragmentów nie da się bezpiecznie
  nanieść na treść w Markdownie albo zapisana w kolejce treść nie jest dokładnie
  zamaskowana, post nie jest publikowany, tylko czeka na moderatora.
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
   (np. zły klucz, profil spoza listy klucza), zobaczysz tam komunikat z kodem błędu. Tam
   też pojawia się informacja, do której godziny brama nie przyjmuje postów (wyczerpany
   dobowy limit klucza, przeciążenie).

## Ustawienia

| Ustawienie | Domyślnie | Znaczenie |
|---|---|---|
| `minos_enabled` | wyłączone | Włącza moderację nowych postów. |
| `minos_gateway_url` | `https://gateway.wergiliusz.app` | Adres bramy. Wymagany `https`; zwykłe `http` działa tylko z atrapą bramy na tym samym komputerze (`localhost`). |
| `minos_api_key` | puste | Klucz forum (nagłówek `X-Gateway-Key`). Pole tajne: nie trafia do logów ani na strony. |
| `minos_webhook_secret` | puste | Sekret, którym brama podpisuje dostawy. Bez niego żaden werdykt nie zostanie przyjęty. Pole tajne. |
| `minos_profile` | `forum_adult` | Profil oceny: `forum_adult` (forum dla dorosłych) albo `forum_teen` (forum dla nastolatków). Musi być na liście profili klucza. |
| `minos_failure_mode` | `fail-closed` | Co zrobić z postem bez oceny: `fail-open` — opublikować, `fail-closed` — zostawić moderatorom. |
| `minos_timeout_minutes` | `20` | Po ilu minutach bez werdyktu post jest traktowany jak nieoceniony. Najmniej 20: brama próbuje doręczać werdykt przez 15 minut, a wtyczka zostawia margines. Mniejsza wartość zapisana we wcześniejszej wersji działa jak 20. |
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
  Forum działa płynnie, ale w czasie awarii nic nie jest moderowane. Wyjątek: post, który
  Discourse wstrzymał sam, albo który moderator zmienił w kolejce, zawsze czeka na
  moderatora.

Jeśli werdykt dla posta opublikowanego w ten sposób jednak przyjdzie później, wtyczka go
stosuje: przy `zablokowane` post zostaje **ukryty** (moderator może go przywrócić), przy
`ocenzurowane` fragmenty zostają zamaskowane w opublikowanym poście (albo post zostaje
ukryty, jeśli tak każe `minos_censored_action` albo maskowania nie da się nanieść), a przy
`bezpieczne` nic się nie zmienia. Jeśli w międzyczasie ktoś już zajął się postem (edycja,
ukrycie, usunięcie, rozpatrzona flaga), jego decyzja zostaje. Post z sygnałem wsparcia
nigdy nie jest ukrywany: zostaje widoczny, a moderatorzy dostają notatkę.

To samo ustawienie decyduje o postach dłuższych niż 3000 znaków: brama ocenia tylko ich
początek, więc przy `fail-closed` taki post (jeśli nie został zablokowany) czeka na
moderatora, a przy `fail-open` jest publikowany według werdyktu dla początku. Post, którego
początek wymagał maskowania (`ocenzurowane`), zawsze czeka na moderatora — w obu trybach.

Chwilowe przeciążenie bramy (odpowiedzi 429 i 503) nie jest awarią: wtyczka ponawia
wysyłkę po czasie, który poda brama (najwyżej po 15 minutach), a bez niego po 1, 2, 4…
minutach. Gdy brama odmawia na dłużej, niż post może czekać na werdykt
(`minos_timeout_minutes`) — np. po wyczerpaniu dobowego limitu klucza — post od razu
przechodzi w tryb awarii, bez czekania. Przy wyczerpanym limicie dobowym i przy
przeciążeniu bramy pulpit administratora pokazuje, do której godziny (UTC) brama nie
przyjmuje postów; komunikat znika o tej godzinie albo po pierwszej przyjętej wysyłce.

Wyłączenie wtyczki niczego nie publikuje ani nie usuwa: wstrzymane posty zostają w
kolejce przeglądu dla moderatorów.

## Limit żądań Discourse a dostawy werdyktów

Discourse ogranicza liczbę żądań z jednego adresu IP: domyślnie 50 na 10 sekund i 200 na
minutę, w trybie `block`. Wszystkie dostawy werdyktów przychodzą z adresów bramy, więc
liczą się do tego limitu. Przy nagłym wysypie postów część dostaw dostanie odpowiedź 429;
brama ponawia je sama (po 5, 10, 20… sekundach, przez 15 minut), więc zwykle nic nie
ginie — werdykt przychodzi tylko później. Na dużym forum, gdzie w ciągu 10 sekund może
powstać więcej niż kilkadziesiąt postów, podnieś limit w `containers/app.yml`, w sekcji
`env`, i przebuduj kontener:

```yaml
env:
  DISCOURSE_MAX_REQS_PER_IP_PER_10_SECONDS: 100
  DISCOURSE_MAX_REQS_PER_IP_PER_MINUTE: 400
```

Werdykt, który mimo ponowień nie dotrze w czasie `minos_timeout_minutes`, trafia do
ustawienia `minos_failure_mode`.

## Co wtyczka wysyła, a czego nigdy

Do bramy trafia, dla każdego wstrzymanego posta:

- **identyfikator** `discourse:<numer zgłoszenia w kolejce>.<numer próby>` — bez żadnej
  treści; każda ponowna wysyłka ma własny numer. Werdykt dla wcześniejszej próby jest
  stosowany tylko wtedy, gdy ta próba wysłała ten sam tekst co ostatnia (i tylko raz na
  post); inaczej jest pomijany;
- **tekst** — taki, jaki widzi czytelnik: tytuł nowego tematu (jeśli to nowy temat),
  pusty wiersz i treść posta. Usuwane są znaczniki Markdownu i HTML (np. `**`, `*`,
  `[quote]`, `<b>`, komentarze `<!-- -->` razem z treścią), encje HTML zamieniane są na
  znaki (np. `&#117;` na `u`), a znaki niewidoczne (np. miękki dywiz) znikają — tak,
  żeby słowo rozdzielone znacznikiem dotarło do bramy w całości. Zostaje każde słowo,
  które czytelnik może zobaczyć — także w cytatach (razem z nazwą pokazaną w nagłówku
  cytatu), spoilerach, podsumowaniach sekcji zwijanych, tekstach alternatywnych i
  tytułach obrazków, żeby nie dało się niczego w nich ukryć. Kod (w blokach i między
  grawisami) idzie tak, jak jest zapisany, bo tak go widzi czytelnik. `[quote=…]`,
  którego Discourse nie pokazuje jako cytatu (np. w środku linii albo bez zamknięcia),
  idzie dosłownie. Podpowiedź, którą Discourse pokazuje po najechaniu kursorem (atrybut
  `title`), idzie zaraz po słowie, którego dotyczy; innych atrybutów HTML, np. adresów
  linków, wtyczka nie wysyła. Wysyłane jest **pierwsze 3000 znaków** (limit bramy);
- **profil** z ustawienia `minos_profile`;
- **sygnały antyspamowe**: liczba linków w poście, to, czy to pierwszy post autora, oraz
  do 10 domen, do których prowadzą linki i obrazki (np. `example.com`, bez reszty adresu).

Wtyczka **nigdy** nie wysyła danych autora — adresu e-mail, adresu IP, identyfikatora ani
nazwy użytkownika — ani wiadomości prywatnych. Klucz trafia wyłącznie do nagłówka żądania do
bramy; ani klucz, ani sekret nie są zapisywane w logach ani pokazywane na stronach. W
logach Discourse wtyczka zapisuje tylko numer zgłoszenia, status HTTP i kod błędu bramy.

Stan każdego wstrzymanego posta (czasy, próby, werdykt bez zamaskowanego tekstu i skrót
kryptograficzny treści, nigdy sama treść) wtyczka trzyma w bazie forum i usuwa po 30
dniach. Oryginalna treść posta opublikowanego z maskowaniem zostaje dla moderatorów tylko
w historii zgłoszenia albo w historii edycji posta.

## Dla programistów

Budowa wtyczki, testy i praca z atrapą bramy: [`docs/development.md`](docs/development.md)
(po angielsku). Kontrakt bramy: `docs/contract.md` w repozytorium
`minos-moderation/client-php`.
