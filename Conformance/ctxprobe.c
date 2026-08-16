/* ctxprobe.c - contexts, allocation, alarm codes and adaptation state
 *
 * Compiled against both libraries and compared.  What is being measured
 * here is mostly policy rather than arithmetic: which allocation sizes are
 * refused, what a duplicated context inherits, and which value a setter
 * hands back — the places where a plausible answer and the right answer
 * are easy to confuse.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdio.h>
#include <string.h>

static void print_codes(const char* label, const cmsUInt16Number* codes)
{
    printf("%-26s", label);
    for (int i = 0; i < 16; i++) printf(" %04x", codes[i]);
    printf("\n");
}

int main(void)
{
    /* -- allocation policy ---------------------------------------------- */

    /* The sizes either side of every rule: zero, the 512 MiB ceiling, and
     * one byte past it.  A block that is refused must be refused by both. */
    static const cmsUInt32Number sizes[] = {
        0, 1, 2, 4096, 1024u * 1024u,
        512u * 1024u * 1024u,        /* the limit itself, allowed */
        512u * 1024u * 1024u + 1u,   /* one past, refused */
        1024u * 1024u * 1024u,
        0xFFFFFFFFu
    };

    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        void* p = _cmsMalloc(NULL, sizes[i]);
        printf("malloc %-12u %s\n", (unsigned) sizes[i], p ? "ok" : "refused");
        if (p) _cmsFree(NULL, p);

        void* z = _cmsMallocZero(NULL, sizes[i]);
        if (z) {
            /* Zeroed means zeroed: check a byte at each end. */
            const unsigned char* b = (const unsigned char*) z;
            printf("  zeroed %d\n", b[0] == 0 && b[sizes[i] - 1] == 0);
            _cmsFree(NULL, z);
        } else {
            printf("  zeroed refused\n");
        }
    }

    /* calloc's overflow rules: the product wraps, and the reference
     * catches it three different ways. */
    static const cmsUInt32Number pairs[][2] = {
        { 0, 0 }, { 0, 16 }, { 16, 0 }, { 1, 1 }, { 16, 16 },
        { 65536, 65536 },          /* wraps to exactly 0 */
        { 65537, 65537 },          /* wraps to something small */
        { 0xFFFFFFFFu, 2 },
        { 2, 0xFFFFFFFFu },
        { 1024, 1024 },            /* 1 MiB, allowed */
        { 1024, 1024 * 1024 },     /* 1 GiB, refused */
    };

    for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++) {
        void* p = _cmsCalloc(NULL, pairs[i][0], pairs[i][1]);
        printf("calloc %u x %-12u %s\n",
               (unsigned) pairs[i][0], (unsigned) pairs[i][1], p ? "ok" : "refused");
        if (p) _cmsFree(NULL, p);
    }

    /* realloc and dup carry their own rules: realloc admits zero where
     * malloc refuses it, and dup of a null source still allocates. */
    {
        void* p = _cmsMalloc(NULL, 128);
        p = _cmsRealloc(NULL, p, 4096);
        printf("realloc grow %s\n", p ? "ok" : "refused");
        void* q = _cmsRealloc(NULL, p, 512u * 1024u * 1024u + 1u);
        printf("realloc over limit %s\n", q ? "ok" : "refused");
        _cmsFree(NULL, q ? q : p);

        _cmsFree(NULL, NULL);  /* must be a no-op, not a crash */
        printf("free(NULL) survived\n");

        const char* text = "the quick brown fox";
        void* d = _cmsDupMem(NULL, text, (cmsUInt32Number) strlen(text) + 1);
        printf("dup %s\n", d && strcmp((char*) d, text) == 0 ? "ok" : "wrong");
        _cmsFree(NULL, d);

        void* dn = _cmsDupMem(NULL, NULL, 64);
        printf("dup of NULL %s\n", dn ? "allocated" : "refused");
        _cmsFree(NULL, dn);
    }

    /* -- contexts -------------------------------------------------------- */

    {
        cmsContext a = cmsCreateContext(NULL, (void*) 0x1234);
        printf("create %s\n", a ? "ok" : "failed");
        printf("user data %p\n", cmsGetContextUserData(a));
        printf("global user data %p\n", cmsGetContextUserData(NULL));

        cmsContext b = cmsDupContext(a, NULL);
        printf("dup inherits user data %p\n", cmsGetContextUserData(b));

        cmsContext c = cmsDupContext(a, (void*) 0x5678);
        printf("dup with new user data %p\n", cmsGetContextUserData(c));

        cmsDeleteContext(c);
        cmsDeleteContext(b);
        cmsDeleteContext(a);
    }

    /* -- alarm codes ----------------------------------------------------- */

    {
        cmsUInt16Number codes[16];
        cmsUInt16Number mine[16];

        cmsGetAlarmCodes(codes);
        print_codes("default alarm codes", codes);

        for (int i = 0; i < 16; i++) mine[i] = (cmsUInt16Number) (0x1000 + i);
        cmsSetAlarmCodes(mine);
        cmsGetAlarmCodes(codes);
        print_codes("after set", codes);

        /* A fresh context starts from the defaults, not from whatever the
         * global context was last set to. */
        cmsContext ctx = cmsCreateContext(NULL, NULL);
        cmsGetAlarmCodesTHR(ctx, codes);
        print_codes("fresh context", codes);

        /* A duplicate inherits the original's, and later changes to the
         * original do not reach it. */
        cmsSetAlarmCodesTHR(ctx, mine);
        cmsContext dup = cmsDupContext(ctx, NULL);
        cmsGetAlarmCodesTHR(dup, codes);
        print_codes("dup inherits", codes);

        cmsUInt16Number changed[16];
        for (int i = 0; i < 16; i++) changed[i] = 0xFFFF;
        cmsSetAlarmCodesTHR(ctx, changed);
        cmsGetAlarmCodesTHR(dup, codes);
        print_codes("dup after original set", codes);

        cmsDeleteContext(dup);
        cmsDeleteContext(ctx);

        /* Put the global context back so the ordering of these blocks
         * cannot change what a later one sees. */
        cmsUInt16Number defaults[16] = { 0x7F00, 0x7F00, 0x7F00 };
        cmsSetAlarmCodes(defaults);
    }

    /* -- adaptation state ------------------------------------------------ */

    {
        /* Always answers the previous value; a negative argument reads
         * without writing. */
        printf("adaptation default %g\n", cmsSetAdaptationState(-1.0));
        printf("set 0.5 returns %g\n", cmsSetAdaptationState(0.5));
        printf("read back %g\n", cmsSetAdaptationState(-1.0));
        printf("set 0 returns %g\n", cmsSetAdaptationState(0.0));
        printf("read back %g\n", cmsSetAdaptationState(-99.0));

        cmsContext ctx = cmsCreateContext(NULL, NULL);
        printf("fresh context state %g\n", cmsSetAdaptationStateTHR(ctx, -1.0));
        cmsSetAdaptationStateTHR(ctx, 0.25);
        cmsContext dup = cmsDupContext(ctx, NULL);
        printf("dup inherits %g\n", cmsSetAdaptationStateTHR(dup, -1.0));
        cmsSetAdaptationStateTHR(ctx, 0.75);
        printf("dup after original set %g\n", cmsSetAdaptationStateTHR(dup, -1.0));
        cmsDeleteContext(dup);
        cmsDeleteContext(ctx);

        cmsSetAdaptationState(1.0);
    }

    /* -- mutexes ---------------------------------------------------------- */

    {
        void* m = _cmsCreateMutex(NULL);
        printf("mutex created %s\n", m ? "yes" : "no");
        printf("lock returns %d\n", _cmsLockMutex(NULL, m));
        _cmsUnlockMutex(NULL, m);
        _cmsDestroyMutex(NULL, m);
        printf("mutex round trip survived\n");
    }

    printf("context probe OK\n");
    return 0;
}
