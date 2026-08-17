/* dictprobe.c - dictionaries and profile sequences, against the reference
 *
 * Both of these hand the caller a structure to walk rather than a handle
 * to ask, so the probe walks them the way a client would: following the
 * dictionary's Next pointers, and indexing and writing into the
 * sequence's array.  The layouts are published, so this is the shape of
 * every real use.
 */

#include "lcms2.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

static void show_wide(const char* label, const wchar_t* s)
{
    printf("%s", label);
    if (s == NULL) { printf("(none)"); return; }
    for (const wchar_t* p = s; *p; p++) printf("%lc", (wint_t) *p);
}

static void walk(cmsHANDLE dict, const char* label)
{
    printf("-- %s\n", label);
    int n = 0;
    for (const cmsDICTentry* e = cmsDictGetEntryList(dict); e != NULL; e = cmsDictNextEntry(e)) {
        printf("  [%d] ", n++);
        show_wide("name '", e->Name);
        show_wide("' value '", e->Value);
        printf("' displayName %s displayValue %s\n",
               e->DisplayName ? "yes" : "no",
               e->DisplayValue ? "yes" : "no");
    }
    printf("  entries %d\n", n);
}

int main(void)
{
    /* -- dictionaries ------------------------------------------------------ */
    {
        cmsHANDLE dict = cmsDictAlloc(NULL);
        printf("allocated %d\n", dict != NULL);
        walk(dict, "empty");

        cmsMLU* display = cmsMLUalloc(NULL, 0);
        cmsMLUsetASCII(display, "en", "US", "a display name");

        cmsDictAddEntry(dict, L"first", L"1", NULL, NULL);
        cmsDictAddEntry(dict, L"second", L"2", display, NULL);
        cmsDictAddEntry(dict, L"third", NULL, NULL, display);

        /* The order matters and is not the order they went in: entries
         * are prepended, so walking gives the newest first. */
        walk(dict, "three entries");

        /* A duplicated dictionary reverses again, so it comes back in
         * insertion order. */
        cmsHANDLE copy = cmsDictDup(dict);
        walk(copy, "duplicate");

        /* The copy owns its own strings and outlives the original. */
        cmsDictFree(dict);
        walk(copy, "duplicate after original freed");
        cmsDictFree(copy);

        cmsMLUfree(display);

        /* An entry with no value at all is still an entry. */
        cmsHANDLE bare = cmsDictAlloc(NULL);
        cmsDictAddEntry(bare, L"lonely", NULL, NULL, NULL);
        walk(bare, "value-less entry");
        cmsDictFree(bare);

        /* Walking nothing. */
        printf("list of nothing -> %s\n", cmsDictGetEntryList(NULL) ? "some" : "none");
        printf("next of nothing -> %s\n", cmsDictNextEntry(NULL) ? "some" : "none");
        /* Not exercised: cmsDictDup and cmsDictFree with no dictionary.
         * The reference asserts and aborts, where this library returns
         * nothing — a probe asking would be measuring an assertion, and
         * being the more careful of the two is not a difference. */
    }

    /* -- profile sequences -------------------------------------------------- */
    {
        printf("zero profiles -> %s\n",
               cmsAllocProfileSequenceDescription(NULL, 0) ? "made" : "refused");
        printf("256 profiles -> %s\n",
               cmsAllocProfileSequenceDescription(NULL, 256) ? "made" : "refused");
        printf("255 profiles -> %s\n",
               cmsAllocProfileSequenceDescription(NULL, 255) ? "made" : "refused");

        cmsSEQ* seq = cmsAllocProfileSequenceDescription(NULL, 3);
        printf("n %u seq %s\n", seq->n, seq->seq ? "present" : "absent");

        /* A client fills these in by indexing the array, and hangs its
         * own strings off the entries. */
        for (cmsUInt32Number i = 0; i < seq->n; i++) {
            seq->seq[i].deviceMfg = (cmsSignature) (0x4D464700 + i);
            seq->seq[i].deviceModel = (cmsSignature) (0x4D4F4400 + i);
            seq->seq[i].technology = (cmsTechnologySignature) (0x74656300 + i);
            memset(&seq->seq[i].attributes, (int) i, sizeof(cmsUInt64Number));
            memset(&seq->seq[i].ProfileID, (int) (0x10 + i), sizeof(cmsProfileID));

            seq->seq[i].Manufacturer = cmsMLUalloc(NULL, 0);
            cmsMLUsetASCII(seq->seq[i].Manufacturer, "en", "US", "maker");
            seq->seq[i].Description = cmsMLUalloc(NULL, 0);
            cmsMLUsetASCII(seq->seq[i].Description, "en", "US", "described");
        }

        for (cmsUInt32Number i = 0; i < seq->n; i++) {
            char text[64] = { 0 };
            cmsMLUgetASCII(seq->seq[i].Manufacturer, "en", "US", text, sizeof text);
            printf("entry %u mfg %08x model %08x tech %08x id0 %02x '%s' model-string %s\n",
                   i,
                   (unsigned) seq->seq[i].deviceMfg,
                   (unsigned) seq->seq[i].deviceModel,
                   (unsigned) seq->seq[i].technology,
                   seq->seq[i].ProfileID.ID8[0],
                   text,
                   seq->seq[i].Model ? "yes" : "no");
        }

        /* The duplicate copies the strings rather than sharing them. */
        cmsSEQ* copy = cmsDupProfileSequenceDescription(seq);
        printf("copy n %u distinct storage %d\n",
               copy->n, copy->seq[0].Manufacturer != seq->seq[0].Manufacturer);

        cmsFreeProfileSequenceDescription(seq);

        for (cmsUInt32Number i = 0; i < copy->n; i++) {
            char text[64] = { 0 };
            cmsMLUgetASCII(copy->seq[i].Manufacturer, "en", "US", text, sizeof text);
            printf("copy entry %u mfg %08x '%s' id0 %02x\n",
                   i, (unsigned) copy->seq[i].deviceMfg, text, copy->seq[i].ProfileID.ID8[0]);
        }
        cmsFreeProfileSequenceDescription(copy);

        printf("dup of nothing -> %s\n",
               cmsDupProfileSequenceDescription(NULL) ? "made" : "refused");
        cmsFreeProfileSequenceDescription(NULL);
        printf("freeing nothing survived\n");
    }

    printf("dictionary probe OK\n");
    return 0;
}
