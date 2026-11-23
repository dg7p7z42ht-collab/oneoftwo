# Ogłoszenia ze zdjęciami w OneOfTwo-Staging

## 1. Przygotuj bazę testową

1. Zaloguj się do panelu Supabase i otwórz projekt **OneOfTwo-Staging**.
2. Wybierz **SQL Editor → New query**. Wklej cały plik [listings.sql](listings.sql) i kliknij **Run**.
3. Po udanym wykonaniu w **Table Editor** będzie widoczna tabela `listings`, a w **Storage** prywatny bucket `listing-images`. Jeśli edytor pokaże błąd, zapisz jego treść. Skrypt działa w transakcji.

Skrypt obsługuje świeżą bazę i istniejący zgodny schemat. Zachowuje typ i wartości w kolumnie `id`. Wymagane dotychczasowe pola to `id`, `user_id`, `title`, `description`, `category`, `listing_type`, `publication_status` i `created_at`. Dodaje brakujące kolumny obrazu i identyfikator używany do ponawiania zapisu. Bucket przyjmuje JPG, PNG i WebP do 10 MiB.

## 2. Otwórz lokalną wersję

Rozpakuj pakiet OneOfTwo-Staging dla Windows i uruchom `Uruchom OneOfTwo-Staging.cmd`. Potrzebny jest Node.js. W oknie programu wklej **Project URL** projektu OneOfTwo-Staging i jego publiczny klucz **Publishable** lub **anon**. Następnie otwórz w przeglądarce `http://localhost:8080`. Program odrzuca znany adres projektu produkcyjnego i klucze tajne. Adres i klucz publiczny wprowadza się przy uruchamianiu. SMTP pozostaje w panelu Supabase.

## 3. Sprawdź ogłoszenie i zdjęcie

1. Zaloguj się kontem testowym. Kliknij **Add Listing**, wybierz typ i kategorię, wpisz nazwę i opis, a następnie dodaj plik JPG, PNG lub WebP.
2. Kliknij **Preview listing** i sprawdź zdjęcie. Zapisz **Save as draft** i wróć do szkicu przez **Your drafts** w panelu.
3. Przed publikacją sprawdź w osobnym oknie prywatnym, że szkicu nie widać na liście kategorii. Drugie konto testowe nie powinno mieć dostępu do cudzego szkicu.
4. Wróć do swojego szkicu, wybierz **Publish listing** i otwórz odpowiednią kategorię w oknie prywatnym. Sprawdź, czy karta pokazuje nazwę, typ i zdjęcie oraz czy otwiera szczegóły. Szkic powinien zniknąć z **Your drafts**.

## Dane i dostęp

Nowe zdjęcia są przechowywane pod ścieżką właściciela w prywatnym buckecie. Zapis i usuwanie ogłoszeń ograniczają polityki RLS. Szkice i nieopublikowane zdjęcia są dostępne właścicielowi. Gość może odczytać opublikowane ogłoszenie i uzyskać czasowy adres zdjęcia. Adres podpisany działa do upływu jego ważności. Przeglądarka usuwa zastąpione zdjęcia po potwierdzonym zapisie, jeśli żadne ogłoszenie ich nie używa. Przerwanie procesu po przesłaniu pliku może pozostawić nieużywany plik prywatny.

Przed ewentualnym wdrożeniem produkcyjnym sprawdź istniejący schemat, polityki i pliki oraz przygotuj kopię zapasową. Starsze adresy z bucketa `listing-images` są mapowane na ścieżki, jeśli pasują do właściciela i istniejącego obiektu. Skrypt przerywa zmianę publicznego bucketa na prywatny, gdy któregoś takiego adresu nie da się zmapować. Zmiana prywatności istniejącego bucketa wymaga skoordynowania z udostępnieniem nowej wersji odczytującej adresy podpisane.
