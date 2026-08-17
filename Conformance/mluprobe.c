/* mluprobe.c - multi-localized strings, against the reference
 *
 * Two things are easy to get subtly wrong here.  Which translation a
 * lookup finds, because the fallback is not "exact match or nothing" —
 * a language match with the wrong country beats nothing, and the first
 * entry beats no match at all.  And the buffer protocol, which every
 * accessor shares: a null buffer asks the size, a short buffer truncates
 * and still terminates, and the count includes the terminator.
 */

#include "lcms2.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

static void show_ascii(cmsMLU* mlu, const char* lang, const char* country, const char* label)
{
    char buffer[64];
    cmsUInt32Number needed = cmsMLUgetASCII(mlu, lang, country, NULL, 0);
    cmsUInt32Number got = cmsMLUgetASCII(mlu, lang, country, buffer, sizeof buffer);

    char obtainedLang[3] = { 0, 0, 0 };
    char obtainedCountry[3] = { 0, 0, 0 };
    cmsBool found = cmsMLUgetTranslation(mlu, lang, country, obtainedLang, obtainedCountry);

    printf("%-22s needed %2u got %2u '%s' via %d '%c%c'/'%c%c'\n",
           label, needed, got, got ? buffer : "",
           found,
           obtainedLang[0] ? obtainedLang[0] : '-', obtainedLang[1] ? obtainedLang[1] : '-',
           obtainedCountry[0] ? obtainedCountry[0] : '-', obtainedCountry[1] ? obtainedCountry[1] : '-');
}

int main(void)
{
    /* -- the fallback ---------------------------------------------------- */
    {
        cmsMLU* mlu = cmsMLUalloc(NULL, 0);
        cmsMLUsetASCII(mlu, "en", "US", "colour in American");
        cmsMLUsetASCII(mlu, "en", "GB", "colour in British");
        cmsMLUsetASCII(mlu, "fr", "FR", "couleur");

        printf("count %u\n", cmsMLUtranslationsCount(mlu));

        /* Exact, language-only, and a language the table has never seen —
         * which still comes back with the first entry rather than
         * nothing. */
        show_ascii(mlu, "en", "US", "exact en-US");
        show_ascii(mlu, "en", "GB", "exact en-GB");
        show_ascii(mlu, "en", "ZZ", "language only");
        show_ascii(mlu, "de", "DE", "unknown language");
        /* Not exercised either: an empty code string.  The
         * reference's strTo16 reads two bytes unconditionally, so ""
         * reads past the literal — what it finds is whatever the linker
         * put next. */
        show_ascii(mlu, NULL, NULL, "null codes");

        /* The directory, in order. */
        for (cmsUInt32Number i = 0; i < cmsMLUtranslationsCount(mlu); i++) {
            char l[3] = { 0, 0, 0 }, c[3] = { 0, 0, 0 };
            cmsBool ok = cmsMLUtranslationsCodes(mlu, i, l, c);
            printf("entry %u -> %d '%c%c' '%c%c'\n", i, ok, l[0], l[1], c[0], c[1]);
        }
        printf("entry past end -> %d\n",
               cmsMLUtranslationsCodes(mlu, 99, (char[3]){0}, (char[3]){0}));

        /* Setting the same pair twice replaces rather than appends. */
        cmsMLUsetASCII(mlu, "en", "US", "replaced");
        printf("count after replace %u\n", cmsMLUtranslationsCount(mlu));
        show_ascii(mlu, "en", "US", "after replace");

        cmsMLUfree(mlu);
    }

    /* -- the buffer protocol --------------------------------------------- */
    {
        cmsMLU* mlu = cmsMLUalloc(NULL, 1);
        cmsMLUsetASCII(mlu, "en", "US", "0123456789");

        for (cmsUInt32Number size = 0; size <= 13; size++) {
            char buffer[32];
            memset(buffer, '#', sizeof buffer);
            cmsUInt32Number got = cmsMLUgetASCII(mlu, "en", "US", buffer, size);
            printf("ascii size %2u -> %2u '", size, got);
            for (cmsUInt32Number i = 0; i < size && i < 16; i++)
                putchar(buffer[i] == 0 ? '.' : buffer[i]);
            printf("'\n");
        }

        for (cmsUInt32Number size = 0; size <= 48; size += 4) {
            wchar_t buffer[32];
            cmsUInt32Number got = cmsMLUgetWide(mlu, "en", "US", buffer, size);
            printf("wide size %2u -> %2u len %zu\n",
                   size, got, size >= sizeof(wchar_t) ? wcslen(buffer) : (size_t) 0);
        }

        printf("wide needed %u\n", cmsMLUgetWide(mlu, "en", "US", NULL, 0));
        printf("utf8 needed %u\n", cmsMLUgetUTF8(mlu, "en", "US", NULL, 0));
        cmsMLUfree(mlu);
    }

    /* -- wide and UTF-8 round trips --------------------------------------- */
    {
        cmsMLU* mlu = cmsMLUalloc(NULL, 0);

        static const wchar_t wide[] = { 'W', 'i', 'd', 'e', 0x00E9, 0x4E2D, 0 };
        cmsMLUsetWide(mlu, "zz", "ZZ", wide);

        wchar_t back[32];
        cmsUInt32Number got = cmsMLUgetWide(mlu, "zz", "ZZ", back, sizeof back);
        printf("wide round trip %u len %zu equal %d\n",
               got, wcslen(back), wcscmp(back, wide) == 0);

        /* Through ASCII, where anything past a byte becomes a question
         * mark — and the boundary is 0xFF, not 0x80. */
        char ascii[32];
        cmsMLUgetASCII(mlu, "zz", "ZZ", ascii, sizeof ascii);
        printf("as ascii '%s'\n", ascii);

        char utf8[64];
        cmsUInt32Number n = cmsMLUgetUTF8(mlu, "zz", "ZZ", utf8, sizeof utf8);
        printf("as utf8 %u bytes:", n);
        for (cmsUInt32Number i = 0; i < n; i++) printf(" %02x", (unsigned char) utf8[i]);
        printf("\n");

        /* And back in through UTF-8. */
        cmsMLU* other = cmsMLUalloc(NULL, 0);
        cmsMLUsetUTF8(other, "zz", "ZZ", utf8);
        wchar_t again[32];
        cmsMLUgetWide(other, "zz", "ZZ", again, sizeof again);
        printf("utf8 round trip equal %d\n", wcscmp(again, wide) == 0);

        cmsMLUfree(other);
        cmsMLUfree(mlu);
    }

    /* -- duplication and lifetimes ---------------------------------------- */
    {
        cmsMLU* mlu = cmsMLUalloc(NULL, 0);
        cmsMLUsetASCII(mlu, "en", "US", "original");
        cmsMLU* copy = cmsMLUdup(mlu);

        /* The copy keeps what it was given after the original changes. */
        cmsMLUsetASCII(mlu, "en", "US", "changed");
        show_ascii(mlu, "en", "US", "original changed");
        show_ascii(copy, "en", "US", "copy unaffected");

        cmsMLUfree(mlu);
        show_ascii(copy, "en", "US", "copy outlives");
        cmsMLUfree(copy);
    }

    /* -- refusals ---------------------------------------------------------- */
    {
        cmsMLU* empty = cmsMLUalloc(NULL, 0);
        char buffer[16];
        printf("empty count %u\n", cmsMLUtranslationsCount(empty));
        printf("empty ascii %u\n", cmsMLUgetASCII(empty, "en", "US", buffer, sizeof buffer));
        printf("empty translation %d\n", cmsMLUgetTranslation(empty, "en", "US", NULL, NULL));
        cmsMLUfree(empty);

        printf("null mlu count %u\n", cmsMLUtranslationsCount(NULL));
        printf("null mlu ascii %u\n", cmsMLUgetASCII(NULL, "en", "US", buffer, sizeof buffer));
        printf("dup of nothing -> %s\n", cmsMLUdup(NULL) ? "made" : "refused");
        cmsMLUfree(NULL);
        printf("freeing nothing survived\n");

        /* Deliberately not exercised: cmsMLUsetASCII with a null string.
         * The reference dereferences it without a check and dies, where
         * this library returns false — being more careful than the thing
         * being measured is not a difference to measure, and a probe that
         * asks is testing undefined behaviour rather than conformance. */
    }

    printf("mlu probe OK\n");
    return 0;
}
