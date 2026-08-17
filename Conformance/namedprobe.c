/* namedprobe.c - named colour lists, against the reference
 *
 * The buffers here are deliberately generous.  cmsNamedColorInfo copies
 * with strcpy rather than strncpy — the reference says so in a comment,
 * because applications pass small buffers — so a caller has to provide
 * room for the whole name.  A probe that passed a short one would be
 * measuring a buffer overrun.
 */

#include "lcms2.h"

#include <stdio.h>
#include <string.h>

static void show(cmsNAMEDCOLORLIST* list, cmsUInt32Number i, const char* label)
{
    char name[256], prefix[64], suffix[64];
    cmsUInt16Number pcs[3], colorant[16];

    memset(name, 0, sizeof name);
    memset(prefix, 0, sizeof prefix);
    memset(suffix, 0, sizeof suffix);
    memset(pcs, 0xAA, sizeof pcs);
    memset(colorant, 0xAA, sizeof colorant);

    cmsBool ok = cmsNamedColorInfo(list, i, name, prefix, suffix, pcs, colorant);
    printf("%-18s [%u] %d '%s' '%s' '%s' pcs %04x %04x %04x colorant",
           label, i, ok, name, prefix, suffix, pcs[0], pcs[1], pcs[2]);
    for (int k = 0; k < 16; k++) printf(" %04x", colorant[k]);
    printf("\n");
}

int main(void)
{
    /* -- building a list -------------------------------------------------- */
    {
        cmsNAMEDCOLORLIST* list = cmsAllocNamedColorList(NULL, 4, 4, "pre", "post");
        printf("allocated %d count %u\n", list != NULL, cmsNamedColorCount(list));

        cmsUInt16Number pcs[3] = { 0x1111, 0x2222, 0x3333 };
        cmsUInt16Number colorant[16];
        for (int i = 0; i < 16; i++) colorant[i] = (cmsUInt16Number) (0x1000 + i);

        printf("append -> %d\n", cmsAppendNamedColor(list, "Red", pcs, colorant));
        printf("append -> %d\n", cmsAppendNamedColor(list, "Green", pcs, colorant));
        /* A missing name, PCS and colorant all become zeroes. */
        printf("append bare -> %d\n", cmsAppendNamedColor(list, NULL, NULL, NULL));
        printf("count %u\n", cmsNamedColorCount(list));

        show(list, 0, "first");
        show(list, 1, "second");
        show(list, 2, "bare");
        show(list, 3, "past end");

        /* Lookup is case-insensitive, and a miss is -1. */
        printf("index 'Red' %d\n", cmsNamedColorIndex(list, "Red"));
        printf("index 'RED' %d\n", cmsNamedColorIndex(list, "RED"));
        printf("index 'red' %d\n", cmsNamedColorIndex(list, "red"));
        printf("index 'Green' %d\n", cmsNamedColorIndex(list, "Green"));
        printf("index 'Blue' %d\n", cmsNamedColorIndex(list, "Blue"));
        printf("index '' %d\n", cmsNamedColorIndex(list, ""));

        /* A duplicate appends rather than replacing — unlike the string
         * table, where a repeated key is refused. */
        cmsAppendNamedColor(list, "Red", pcs, colorant);
        printf("count after duplicate %u index %d\n",
               cmsNamedColorCount(list), cmsNamedColorIndex(list, "Red"));

        /* Growing past the reserved size has to keep working. */
        for (int i = 0; i < 40; i++) {
            char name[32];
            snprintf(name, sizeof name, "colour-%d", i);
            cmsAppendNamedColor(list, name, pcs, colorant);
        }
        printf("count after growth %u\n", cmsNamedColorCount(list));
        printf("index 'colour-39' %d\n", cmsNamedColorIndex(list, "colour-39"));
        show(list, 43, "last");

        /* A duplicate carries the entries and the affixes. */
        cmsNAMEDCOLORLIST* copy = cmsDupNamedColorList(list);
        printf("copy count %u\n", cmsNamedColorCount(copy));
        show(copy, 0, "copy first");
        show(copy, 43, "copy last");

        cmsFreeNamedColorList(list);
        show(copy, 0, "copy outlives");
        cmsFreeNamedColorList(copy);
    }

    /* -- limits and refusals ------------------------------------------------ */
    {
        /* More colorant channels than a colorant can hold. */
        printf("17 channels -> %s\n",
               cmsAllocNamedColorList(NULL, 1, 17, "p", "s") ? "made" : "refused");
        printf("16 channels -> %s\n",
               cmsAllocNamedColorList(NULL, 1, 16, "p", "s") ? "made" : "refused");

        /* Affixes longer than the format's field, which get truncated. */
        const char* longAffix = "0123456789012345678901234567890123456789";
        cmsNAMEDCOLORLIST* list = cmsAllocNamedColorList(NULL, 1, 3, longAffix, longAffix);
        cmsAppendNamedColor(list, "x", NULL, NULL);
        show(list, 0, "long affixes");
        cmsFreeNamedColorList(list);

        /* A name longer than the format's field. */
        char longName[400];
        memset(longName, 'n', sizeof longName - 1);
        longName[sizeof longName - 1] = 0;
        cmsNAMEDCOLORLIST* other = cmsAllocNamedColorList(NULL, 1, 3, "p", "s");
        cmsAppendNamedColor(other, longName, NULL, NULL);
        {
            char name[256] = { 0 };
            cmsNamedColorInfo(other, 0, name, NULL, NULL, NULL, NULL);
            printf("long name kept %zu of %zu\n", strlen(name), strlen(longName));
        }
        cmsFreeNamedColorList(other);

        printf("count of nothing %u\n", cmsNamedColorCount(NULL));
        printf("index in nothing %d\n", cmsNamedColorIndex(NULL, "x"));
        printf("dup of nothing -> %s\n", cmsDupNamedColorList(NULL) ? "made" : "refused");
        cmsFreeNamedColorList(NULL);
        printf("freeing nothing survived\n");
    }

    /* -- the case-insensitive comparison itself ----------------------------- */
    {
        static const char* pairs[][2] = {
            { "abc", "abc" }, { "abc", "ABC" }, { "ABC", "abc" },
            { "abc", "abd" }, { "abd", "abc" },
            { "abc", "ab" }, { "ab", "abc" },
            { "", "" }, { "", "a" }, { "a", "" },
            { "a1", "A1" }, { "[", "{" }, { "Z", "z" },
        };
        for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++) {
            int r = cmsstrcasecmp(pairs[i][0], pairs[i][1]);
            printf("cmp '%s' '%s' -> %s\n", pairs[i][0], pairs[i][1],
                   r == 0 ? "equal" : (r < 0 ? "less" : "greater"));
        }
    }

    printf("named colour probe OK\n");
    return 0;
}
