# Minos — moderacja postów dla Discourse

Wtyczka do samodzielnie hostowanego Discourse, która wstrzymuje nowe posty, wysyła je do
oceny bramie Wergiliusz i stosuje werdykt, który brama odsyła podpisanym webhookiem:
publikuje post, publikuje go z zamaskowanymi fragmentami, odrzuca go albo zostawia
moderatorom — zgodnie z ustawieniami administratora forum. Jest częścią projektu Minos;
licencja GPL-2.0 (plik `LICENSE`).

> **Stan:** trasa B2B bramy jest otwarta produkcyjnie od 25 października 2026 r. Klucz i
> sekret webhooka wydaje operator bramy. Bez klucza wtyczkę można wypróbować z bramą
> testową (atrapą) z repozytorium `minos-moderation/client-php` — patrz
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
   werdykt, kategorie (np. `wulgaryzmy`, `nekanie`), powód i to, co wtyczka zrobiła. Gdy
   post z werdyktem `ocenzurowane` zostaje moderatorom (ustawienie, post dłuższy niż 3000
   znaków, maskowania nie da się nanieść, zapis się nie udał), druga notatka pokazuje
   tekst wysłany do oceny z fragmentami zamaskowanymi przez bramę (`█`), żeby moderator
   widział, co brama chciała ukryć. Notatki zapisuje użytkownik systemowy jako notatki
   zgłoszenia (`ReviewableNote`), które ma bieżący Discourse; na wersji bez nich wtyczka
   działa tak samo, ale notatek nie ma — o decyzji świadczy wtedy tylko stan zgłoszenia
   (opublikowane, odrzucone, czeka). Notatka dłuższa niż 2000 znaków jest skracana, a
   notatka, której nie udało się zapisać, zostawia tylko wpis w logu.

Kilka zasad, które zawsze obowiązują:

- **Wtyczka nigdy nie zgaduje werdyktu.** Wartość, której nie zna, traktuje jak
  `nieocenione`.
- **Sygnał wsparcia.** Gdy brama uzna, że treść może świadczyć o kryzysie autora
  (samookaleczenie, sygnał `wsparcie`), moderatorzy dowiadują się o tym w swojej kolejce
  przeglądu, jaki by nie był werdykt: post wstrzymany czeka w niej z notatką, a post
  opublikowany (od razu albo wcześniej, w trybie `fail-open`) dostaje od użytkownika
  systemowego **flagę „powiadom moderatorów”** z wyjaśnieniem — nowe zgłoszenie w tej
  samej kolejce (Discourse wysyła wtedy wiadomość do grupy moderatorów). Taki post nigdy
  nie jest odrzucany, usuwany ani ukrywany automatycznie, a wtyczka nie wysyła w tej
  sprawie żadnej wiadomości autorowi. O tym decyduje człowiek.
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
posty botów i systemu, **wiadomości prywatne** (Discourse nigdy ich nie kolejkuje, a
ich treść jest prywatna) oraz posty **poza zakresem** wybranym przez administratora
(ustawienia `minos_categories`, `minos_exempt_groups`, `minos_max_trust_level`). Post
poza zakresem **nie jest oceniany wcale**: wtyczka niczego o nim nie wysyła ani nie
zapisuje, a Discourse publikuje go albo wstrzymuje według własnych reguł (np. post
nowego użytkownika nadal czeka na zatwierdzenie, jeśli tak każe forum). Domyślnie zakres
obejmuje wszystkie posty. Jeśli zakresu nie da się ustalić (np. kategoria posta nie
istnieje albo żadna z wybranych kategorii już nie istnieje), post jest moderowany.
Wtyczka nie ocenia **edycji** już opublikowanych postów.

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

   To instalacja z gałęzi `main` — **stan przejściowy** do pierwszego wydania wtyczki
   (tagu `v0.1.0`): przy każdym `./launcher rebuild app` forum pobiera wtedy najnowszy
   stan `main`. Po wydaniu instrukcja wskaże instalację z tagu
   (`git clone --branch v0.1.0 …`), a aktualizacja będzie zmianą tagu w tym wierszu.

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
| `minos_profile` | `forum_adult` | Profil oceny: `forum_adult` (forum dla dorosłych) albo `forum_teen` (forum dla dzieci i młodzieży). Musi być na liście profili klucza. |
| `minos_failure_mode` | `fail-closed` | Co zrobić z postem bez oceny: `fail-open` — opublikować, `fail-closed` — zostawić moderatorom. |
| `minos_timeout_minutes` | `20` | Po ilu minutach bez werdyktu post jest traktowany jak nieoceniony. Najmniej 20: brama próbuje doręczać werdykt przez 15 minut, a wtyczka zostawia margines. Mniejsza wartość zapisana we wcześniejszej wersji działa jak 20. |
| `minos_censored_action` | `publikuj_ocenzurowany` | Werdykt `ocenzurowane`: `publikuj_ocenzurowany` albo `zostaw_moderatorom`. |
| `minos_blocked_action` | `zostaw_moderatorom` | Werdykt `zablokowane`: `zostaw_moderatorom` albo `odrzuc`. |
| `minos_skip_staff` | włączone | Posty moderatorów i administratorów publikowane od razu, bez oceny. |
| `minos_categories` | puste (wszystkie) | Kategorie, w których nowe posty są wstrzymywane i oceniane — także w ich podkategoriach. Post z innej kategorii nie jest oceniany wcale. |
| `minos_exempt_groups` | puste (żadna) | Grupy, których członków wtyczka nie moderuje: ich posty nie są wstrzymywane ani oceniane. |
| `minos_max_trust_level` | `4` (wszyscy) | Najwyższy poziom zaufania autora, którego posty są wstrzymywane i oceniane; np. `1` — tylko nowi i podstawowi użytkownicy. Posty autorów z wyższym poziomem nie są oceniane wcale. |

## `fail-open` czy `fail-closed`

Brama może nie ocenić posta: odpowiedź `nieocenione`, brak werdyktu w czasie
`minos_timeout_minutes`, błąd konfiguracji (np. nieważny klucz) albo post bez własnego
tekstu do oceny. O tym, co wtedy, decyduje `minos_failure_mode`:

- **`fail-closed`** (domyślnie) — post czeka w kolejce przeglądu na moderatora, z notatką,
  dlaczego nie został oceniony. Nic nieocenionego nie trafia na forum samo, ale przy
  dłuższej awarii kolejka rośnie. Jeśli post czekał, bo werdykt nie przyszedł w czasie
  `minos_timeout_minutes`, a werdykt przyjdzie później, gdy nikt jeszcze nie zatwierdził
  ani nie odrzucił posta, wtyczka stosuje go tak, jakby przyszedł na czas (np.
  `bezpieczne` publikuje post). Gdy moderator zdążył już zdecydować, werdykt jest
  pomijany; gdy zmienił treść posta w kolejce, werdykt trafia tylko do notatki.
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
nigdy nie jest ukrywany: zostaje widoczny, a moderatorzy dostają notatkę i flagę w
kolejce przeglądu.

To samo ustawienie decyduje o postach dłuższych niż 3000 znaków: brama ocenia tylko ich
początek, więc przy `fail-closed` taki post (jeśli nie został zablokowany) czeka na
moderatora, a przy `fail-open` jest publikowany według werdyktu dla początku. Post, którego
początek wymagał maskowania (`ocenzurowane`), zawsze czeka na moderatora — w obu trybach.

Wtyczka uznaje post za przyjęty do oceny tylko po odpowiedzi bramy **202**. Chwilowe
przeciążenie bramy nie jest awarią: po odpowiedzi 429 (limit klucza, wspólny limit bramy,
pełna kolejka), 503 i każdej innej 5xx, po przekroczeniu czasu połączenia (także 408),
po błędzie sieci i po odpowiedzi 2xx innej niż 202 wtyczka ponawia wysyłkę po czasie,
który poda brama, a bez niego po 1, 2, 4… minutach (najwyżej po 15). Na ten sam czas
(najwyżej dobę) wstrzymuje wysyłkę **wszystkich** postów: kolejne posty czekają do końca
przerwy, nie wysyłając zapytań, więc pełna kolejka albo wyczerpany limit kosztuje jedno
odrzucone zapytanie, a nie jedno na post. Pierwsza przyjęta wysyłka kończy przerwę, a
zmiana klucza (`minos_api_key`) albo adresu bramy (`minos_gateway_url`) kończy ją od razu,
razem z komunikatem o limicie. Gdy
brama odmawia na dłużej, niż post może czekać na werdykt (`minos_timeout_minutes`) — np.
po wyczerpaniu dobowego limitu klucza — post od razu przechodzi w tryb awarii, bez
czekania i bez zapytania. Każda inna odmowa bramy (inny kod 4xx, przekierowanie) to błąd
konfiguracji: post przechodzi w tryb awarii, a pulpit administratora pokazuje kod. Przy
wyczerpanym limicie dobowym i przy przeciążeniu bramy pulpit administratora pokazuje, do
której godziny (UTC) brama nie przyjmuje postów; komunikat znika o tej godzinie albo po
pierwszej przyjętej wysyłce.

Jeśli werdyktu, który przyszedł, nie da się zastosować (np. przez chwilowy błąd bazy),
wtyczka ponawia próbę co 5 minut, a po **24 godzinach** rezygnuje: post zostaje w stanie,
w jakim był (wstrzymany czeka na moderatora, opublikowany zostaje opublikowany), z
notatką „werdyktu nie udało się zastosować przez dobę”.

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

Wtyczka odpowiada bramie kodem 2xx tylko wtedy, gdy zapisała werdykt. Gdy forum jest w
trybie **tylko do odczytu** (np. podczas przywracania kopii zapasowej), Discourse odpowiada
na dostawę kodem 503, a brama ponawia ją przez około 12 minut od przyjęcia posta: werdykt
doręczony w tym czasie wraca po ponowieniu. Przerwa dłuższa niż około 12 minut gubi
werdykt — post czeka wtedy do końca czasu `minos_timeout_minutes` i przechodzi w tryb
awarii. Wyłączona wtyczka odpowiada na dostawy kodem 404.

## Raport: czas do werdyktu i werdykty

W panelu administratora, w **Raportach**, wtyczka dodaje raport „Minos — czas do werdyktu
i werdykty” (widoczny dla moderatorów i administratorów, gdy wtyczka jest włączona). Z
ostatnich 7 dni pokazuje: medianę (P50) i 95. percentyl (P95) czasu od przyjęcia posta
przez bramę (odpowiedź 202) do doręczenia werdyktu, liczbę postów, dla których ten czas
zmierzono, liczbę werdyktów `bezpieczne`, `ocenzurowane`, `zablokowane` i `nieocenione`
oraz liczbę postów, które zakończyły się bez werdyktu (tryb awarii po upływie czasu,
odmowie bramy albo błędzie konfiguracji). Liczby powstają z czasów i werdyktów, które
wtyczka i tak przechowuje przez 30 dni — raport nie zapisuje niczego nowego, nie wysyła
zapytań do bramy i nie zawiera treści postów, klucza ani sekretu.

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
  idzie dosłownie; tak samo link wpisany wprost (`https://…`) i treść bloku HTML.
  Podpowiedź, którą Discourse pokazuje po najechaniu kursorem (atrybut `title`), oraz
  adres, tytuł i etykieta linku zapisanego w Markdownie idą zaraz po słowie, w którym
  stoją, żeby go nie rozdzielić; innych atrybutów HTML (np. `href` w znaczniku `<a>`) wtyczka nie wysyła.
  Wysyłane jest **pierwsze 3000 znaków** (limit bramy). Post **bez własnego tekstu** —
  którego widoczna treść to tylko obrazek (także z tekstem alternatywnym albo tytułem),
  film, załącznik albo link bez widocznego opisu, ewentualnie ze znakami niewidocznymi
  (np. spacja zerowej szerokości, miękki dywiz) — nie jest wysyłany wcale, nawet z
  tytułem tematu: brama nie ocenia obrazów, a sam adres nie jest treścią. Taki post
  przechodzi w tryb awarii (`minos_failure_mode`). Adres wpisany wprost i widoczny dla
  czytelnika (`https://…`) jest tekstem i jest wysyłany. Tekst alternatywny i tytuł
  obrazka idą tylko obok innych słów posta;
- **profil** z ustawienia `minos_profile`;
- **sygnały antyspamowe**: liczba linków w poście, to, czy to pierwszy post autora, oraz
  do 10 domen, do których prowadzą linki i obrazki (np. `example.com`, bez reszty adresu).

Wtyczka **nigdy** nie wysyła danych autora — adresu e-mail, adresu IP, identyfikatora ani
nazwy użytkownika — ani wiadomości prywatnych. Klucz trafia wyłącznie do nagłówka żądania do
bramy; ani klucz, ani sekret nie są zapisywane w logach ani pokazywane na stronach. W
logach Discourse wtyczka zapisuje ostrzeżenia z numerem zgłoszenia, statusem HTTP i kodem
błędu bramy, czasem do ponowienia, nazwą kroku, który się nie udał, i nazwą klasy błędu
(np. `ActiveRecord::RecordInvalid`) — nigdy treści komunikatu błędu, treści posta, ciała
żądania ani dostawy, klucza ani sekretu.

### Co wtyczka przechowuje i jak długo

Stan każdego wstrzymanego posta (czasy, próby, werdykt bez zamaskowanego tekstu i skrót
kryptograficzny treści, nigdy sama treść) wtyczka trzyma w bazie forum (`PluginStore`) i
usuwa po **30 dniach**. Oryginalnej treści posta wtyczka nie przechowuje wcale.

Dłużej niż 30 dni zostają wpisy w **rejestrach samego Discourse**, które powstają, gdy
wtyczka działa — podlegają one zasadom przechowywania danych forum, a nie wtyczki, i
polityka prywatności forum powinna o nich mówić:

- **historia zgłoszenia w kolejce przeglądu**: oryginalna treść posta opublikowanego z
  maskowaniem prosto z kolejki (zmiana treści zgłoszenia) oraz notatki wtyczki — werdykt,
  kategorie, powód, sygnał wsparcia i, gdy post z werdyktem `ocenzurowane` został
  moderatorom, tekst z maskami bramy; widoczne dla moderatorów i administratorów;
- **historia edycji posta**: oryginalna treść posta zamaskowanego już po publikacji (gdy
  werdykt przyszedł po publikacji w trybie `fail-open`) — w **ukrytej** wersji, którą
  Discourse pokazuje tylko moderatorom i administratorom, także gdy forum udostępnia
  historię edycji wszystkim (`edit_history_visible_to_public`);
- **flaga „powiadom moderatorów”** przy sygnale wsparcia i wiadomość do grupy
  moderatorów, którą Discourse do niej dołącza (bez treści posta).

## Dla programistów

Budowa wtyczki, testy i praca z atrapą bramy: [`docs/development.md`](docs/development.md)
(po angielsku). Kontrakt bramy: `docs/contract.md` w repozytorium
`minos-moderation/client-php`.
