/* it8probe - CGATS/IT8 sheets
 *
 * A sheet is built through the API, written to memory, and the text
 * printed in full: the writer's every choice — quoting, hex, comments,
 * tabs — is on show.  The text is then read back and queried, junk and
 * near-junk are fed to the parser, and a sheet with two tables and
 * multi-valued properties is round-tripped.
 */

#include "lcms2.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    printf("  error %u: %s\n", code, text);
}

static void dump(cmsHANDLE it8, const char* what)
{
    cmsUInt32Number needed = 0;
    cmsIT8SaveToMem(it8, NULL, &needed);
    char* text = (char*) calloc(needed + 1, 1);
    cmsUInt32Number given = needed;
    cmsBool ok = cmsIT8SaveToMem(it8, text, &given);
    printf("-- %s: %u bytes, saved %d, given back %u\n%s--\n", what, needed, ok, given, text);
    free(text);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    cmsSetLogErrorHandler(logger);

    /* -- built through the API, as the testbed builds one -- */
    cmsHANDLE it8 = cmsIT8Alloc(NULL);
    printf("sheet type '%s' tables %u\n", cmsIT8GetSheetType(it8), cmsIT8TableCount(it8));
    cmsIT8SetSheetType(it8, "LCMS/TESTING");
    cmsIT8SetComment(it8, "a comment\nwith two lines");
    cmsIT8SetPropertyStr(it8, "ORIGINATOR", "1 2 3 4");
    cmsIT8SetPropertyUncooked(it8, "DESCRIPTOR", "1234");
    cmsIT8SetPropertyStr(it8, "MANUFACTURER", "3");
    cmsIT8SetPropertyDbl(it8, "CREATED", 4);
    cmsIT8SetPropertyDbl(it8, "SERIAL", 5.5);
    cmsIT8SetPropertyHex(it8, "MATERIAL", 0x123);
    cmsIT8SetPropertyDbl(it8, "NUMBER_OF_SETS", 5);
    cmsIT8SetPropertyDbl(it8, "NUMBER_OF_FIELDS", 4);
    cmsIT8SetPropertyMulti(it8, "WEIGHTING_FUNCTION", "ILLUMINANT", "D50");
    cmsIT8SetPropertyMulti(it8, "WEIGHTING_FUNCTION", "OBSERVER", "1931_2");
    cmsIT8SetPropertyStr(it8, "MY_OWN_KEY", "custom value");
    printf("duplicate count key: %d\n", cmsIT8SetPropertyDbl(it8, "NUMBER_OF_SETS", 6));
    printf("empty string prop: %d\n", cmsIT8SetPropertyStr(it8, "EMPTY", ""));
    cmsIT8SetDataFormat(it8, 0, "SAMPLE_ID");
    cmsIT8SetDataFormat(it8, 1, "RGB_R");
    cmsIT8SetDataFormat(it8, 2, "RGB_G");
    cmsIT8SetDataFormat(it8, 3, "RGB_B");
    printf("too many formats: %d\n", cmsIT8SetDataFormat(it8, 4, "EXTRA"));
    for (int i = 0; i < 5; i++) {
        char patch[20];
        sprintf(patch, "P%d", i);
        cmsIT8SetDataRowCol(it8, i, 0, patch);
        cmsIT8SetDataRowColDbl(it8, i, 1, i * 1.5);
        cmsIT8SetDataRowColDbl(it8, i, 2, i);
        cmsIT8SetDataRowColDbl(it8, i, 3, 100.0 - i / 3.0);
    }
    cmsIT8SetDataRowCol(it8, 2, 2, "has space");
    printf("row out of range: %d\n", cmsIT8SetDataRowCol(it8, 9, 0, "x"));
    printf("get P3 RGB_G %g, RGB_R %g, missing %g\n", cmsIT8GetDataDbl(it8, "P3", "RGB_G"),
           cmsIT8GetDataDbl(it8, "P3", "RGB_R"), cmsIT8GetDataDbl(it8, "P9", "RGB_G"));
    printf("get by name '%s' by rowcol '%s' patch name '%s' index of P4 %d find RGB_B %d\n",
           cmsIT8GetData(it8, "P1", "SAMPLE_ID"), cmsIT8GetDataRowCol(it8, 2, 2),
           cmsIT8GetPatchName(it8, 3, NULL), cmsIT8GetPatchByName(it8, "P4"), cmsIT8FindDataFormat(it8, "RGB_B"));
    printf("props: '%s' '%s' %g multi '%s' '%s' missing '%s'\n",
           cmsIT8GetProperty(it8, "ORIGINATOR"), cmsIT8GetProperty(it8, "MATERIAL"),
           cmsIT8GetPropertyDbl(it8, "SERIAL"),
           cmsIT8GetPropertyMulti(it8, "WEIGHTING_FUNCTION", "OBSERVER"),
           cmsIT8GetPropertyMulti(it8, "WEIGHTING_FUNCTION", "ILLUMINANT"),
           cmsIT8GetProperty(it8, "NOPE") ? "found" : "(null)");
    {
        char** names; char** props; const char** subs;
        int n = cmsIT8EnumDataFormat(it8, &names);
        printf("formats %d:", n);
        for (int i = 0; i < n; i++) printf(" %s", names[i]);
        cmsUInt32Number m = cmsIT8EnumProperties(it8, &props);
        printf("\nproperties %u:", m);
        for (cmsUInt32Number i = 0; i < m; i++) printf(" %s", props[i]);
        cmsUInt32Number k = cmsIT8EnumPropertyMulti(it8, "WEIGHTING_FUNCTION", &subs);
        printf("\nsubproperties %u:", k);
        for (cmsUInt32Number i = 0; i < k; i++) printf(" %s", subs[i] ? subs[i] : "(null)");
        printf("\n");
    }
    dump(it8, "built");

    /* Reload what was written and query again. */
    cmsUInt32Number needed = 0;
    cmsIT8SaveToMem(it8, NULL, &needed);
    char* text = (char*) calloc(needed, 1);
    cmsIT8SaveToMem(it8, text, &needed);
    cmsIT8Free(it8);

    cmsHANDLE re = cmsIT8LoadFromMem(NULL, text, needed - 1);
    printf("reloaded %s\n", re ? "ok" : "(refused)");
    if (re) {
        printf("type '%s' descriptor %g material '%s' P2 RGB_G '%s' P4 RGB_B %g mfg '%s'\n",
               cmsIT8GetSheetType(re), cmsIT8GetPropertyDbl(re, "DESCRIPTOR"),
               cmsIT8GetProperty(re, "MATERIAL"), cmsIT8GetData(re, "P2", "RGB_G"),
               cmsIT8GetDataDbl(re, "P4", "RGB_B"), cmsIT8GetProperty(re, "MANUFACTURER"));
        printf("multi after reload '%s' '%s' custom '%s'\n",
               cmsIT8GetPropertyMulti(re, "WEIGHTING_FUNCTION", "ILLUMINANT"),
               cmsIT8GetPropertyMulti(re, "WEIGHTING_FUNCTION", "OBSERVER"),
               cmsIT8GetProperty(re, "MY_OWN_KEY"));
        cmsIT8SetPropertyDbl(re, "DESCRIPTOR", 5678);
        cmsIT8SetPropertyDbl(re, "DBL_PROP", 123E+12);
        cmsIT8SetPropertyDbl(re, "DBL_PROP_NEG", 123E-45);
        cmsIT8SetPropertyDbl(re, "DBL_NEG_VAL", -123);
        printf("numbers %g %g %g %g\n", cmsIT8GetPropertyDbl(re, "DESCRIPTOR"), cmsIT8GetPropertyDbl(re, "DBL_PROP"),
               cmsIT8GetPropertyDbl(re, "DBL_PROP_NEG"), cmsIT8GetPropertyDbl(re, "DBL_NEG_VAL"));
        cmsIT8DefineDblFormat(re, "%.3f");
        cmsIT8SetPropertyDbl(re, "FORMATTED", 3.14159265);
        printf("formatted '%s'\n", cmsIT8GetProperty(re, "FORMATTED"));
        cmsIT8DefineDblFormat(re, NULL);
        dump(re, "reloaded and changed");
        cmsIT8Free(re);
    }
    free(text);

    /* -- a hand-written sheet with two tables, keywords, hex, binary, includes of a comment -- */
    {
        const char* src =
            "IT8.7/2\n"
            "# leading comment\n"
            "ORIGINATOR\t\"probe\"\n"
            "KEYWORD \"MYKEY\"\n"
            "MYKEY\t0x1F\n"
            "BIN\t0b101\n"
            "NEG\t-42\n"
            "SCI\t1.5e3\n"
            "DATA_FORMAT_IDENTIFIER \"CUSTOM_COL\"\n"
            "WEIGHTING_FUNCTION \"ILLUMINANT, D65 ; OBSERVER,1964_10\"\n"
            "NUMBER_OF_FIELDS 3\n"
            "NUMBER_OF_SETS 2\n"
            "BEGIN_DATA_FORMAT\n"
            "SAMPLE_ID LABEL CUSTOM_COL\n"
            "END_DATA_FORMAT\n"
            "BEGIN_DATA\n"
            "A1 SECOND 12\n"
            "\"A 2\" nothing 3.5\n"
            "END_DATA\n"
            "\n"
            "SECOND\n"
            "NUMBER_OF_FIELDS 2\n"
            "NUMBER_OF_SETS 1\n"
            "SECOND \"the second table\"\n"
            "BEGIN_DATA_FORMAT\n"
            "SAMPLE_ID VAL\n"
            "END_DATA_FORMAT\n"
            "BEGIN_DATA\n"
            "X 7\n"
            "END_DATA\n";
        cmsHANDLE h = cmsIT8LoadFromMem(NULL, src, (cmsUInt32Number) strlen(src));
        printf("two tables: %s\n", h ? "loaded" : "(refused)");
        if (h) {
            printf("count %u type '%s' MYKEY '%s' %g BIN '%s' NEG %g SCI %g\n", cmsIT8TableCount(h), cmsIT8GetSheetType(h),
                   cmsIT8GetProperty(h, "MYKEY"), cmsIT8GetPropertyDbl(h, "MYKEY"), cmsIT8GetProperty(h, "BIN"),
                   cmsIT8GetPropertyDbl(h, "NEG"), cmsIT8GetPropertyDbl(h, "SCI"));
            printf("multi '%s' '%s'\n", cmsIT8GetPropertyMulti(h, "WEIGHTING_FUNCTION", "ILLUMINANT"),
                   cmsIT8GetPropertyMulti(h, "WEIGHTING_FUNCTION", "OBSERVER"));
            printf("A1 label '%s' A 2 custom %g quoted patch '%s'\n", cmsIT8GetData(h, "A1", "LABEL"),
                   cmsIT8GetDataDbl(h, "A 2", "CUSTOM_COL"), cmsIT8GetPatchName(h, 1, NULL));
            printf("set table by label -> %d, then type '%s' X VAL %g\n",
                   cmsIT8SetTableByLabel(h, "A1", "LABEL", NULL), cmsIT8GetSheetType(h), cmsIT8GetDataDbl(h, "X", "VAL"));
            printf("set table by label wrong type -> %d\n", cmsIT8SetTableByLabel(h, "A1", NULL, "OTHER"));
            printf("set table 1 -> %d, 5 -> %d, 2 -> %d count %u\n", cmsIT8SetTable(h, 1), cmsIT8SetTable(h, 5), cmsIT8SetTable(h, 2), cmsIT8TableCount(h));
            cmsIT8SetTable(h, 0);
            printf("set index column CUSTOM_COL %d, patch 0 now '%s'; unknown %d\n", cmsIT8SetIndexColumn(h, "CUSTOM_COL"),
                   cmsIT8GetPatchName(h, 0, NULL), cmsIT8SetIndexColumn(h, "NOPE"));
            cmsIT8SetIndexColumn(h, "SAMPLE_ID");
            /* Adding a patch through SetData with SAMPLE_ID. */
            cmsIT8SetTable(h, 1);
            printf("add patch: %d %d, then Y VAL %g\n", cmsIT8SetData(h, "Y", "SAMPLE_ID", "Y"), cmsIT8SetData(h, "Y", "VAL", "9"),
                   cmsIT8GetDataDbl(h, "Y", "VAL"));
            printf("add another patch (no room): %d\n", cmsIT8SetData(h, "Z", "SAMPLE_ID", "Z"));
            dump(h, "two tables");
            cmsIT8Free(h);
        }
    }

    /* -- junk, near-junk, and overflows -- */
    printf("junk\n");
    {
        static const char junk[] = { 0x00, 0x00, 0x00, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c };
        cmsHANDLE h = cmsIT8LoadFromMem(NULL, junk, sizeof junk);
        printf("  all junk: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* overflow =
            "CGATS.17\n"
            "NUMBER_OF_FIELDS 2\n"
            "NUMBER_OF_SETS 1\n"
            "BEGIN_DATA_FORMAT\n"
            "SAMPLE_ID X\n"
            "END_DATA_FORMAT\n"
            "BEGIN_DATA\n"
            "A 1 2 3\n"
            "END_DATA\n";
        h = cmsIT8LoadFromMem(NULL, overflow, (cmsUInt32Number) strlen(overflow));
        printf("  too many values: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* bad =
            "CGATS.17\n"
            "NUMBER_OF_FIELDS 2\n"
            "NUMBER_OF_SETS 2\n"
            "BEGIN_DATA_FORMAT\n"
            "SAMPLE_ID X\n"
            "END_DATA_FORMAT\n"
            "BEGIN_DATA\n"
            "A 1\n"
            "END_DATA\n";
        h = cmsIT8LoadFromMem(NULL, bad, (cmsUInt32Number) strlen(bad));
        printf("  too few sets: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* unterminated = "CGATS.17\nORIGINATOR \"never closed\nNUMBER_OF_FIELDS 1\n";
        h = cmsIT8LoadFromMem(NULL, unterminated, (cmsUInt32Number) strlen(unterminated));
        printf("  unterminated string: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* badchar = "CGATS.17\nORIGINATOR \x7f\n";
        h = cmsIT8LoadFromMem(NULL, badchar, (cmsUInt32Number) strlen(badchar));
        printf("  bad character: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* toobig = "CGATS.17\nNUMBER_OF_FIELDS 30000\nNUMBER_OF_SETS 30000\nBEGIN_DATA\nEND_DATA\n";
        h = cmsIT8LoadFromMem(NULL, toobig, (cmsUInt32Number) strlen(toobig));
        printf("  too much data: %s\n", h ? "loaded" : "refused");
        if (h) cmsIT8Free(h);

        const char* nosheet = "NUMBER_OF_FIELDS 1\nNUMBER_OF_SETS 1\nBEGIN_DATA_FORMAT\nSAMPLE_ID\nEND_DATA_FORMAT\nBEGIN_DATA\nA\nEND_DATA\n";
        h = cmsIT8LoadFromMem(NULL, nosheet, (cmsUInt32Number) strlen(nosheet));
        printf("  no sheet type line: %s type '%s'\n", h ? "loaded" : "refused", h ? cmsIT8GetSheetType(h) : "");
        if (h) cmsIT8Free(h);
    }
    /* -- .cube devicelinks -- */
    printf("cube\n");
    {
        const char* cube =
            "TITLE \"probe cube\"\n"
            "# a comment\n"
            "DOMAIN_MIN 0 0 0\n"
            "DOMAIN_MAX 1 1 1\n"
            "LUT_1D_SIZE 3\n"
            "LUT_3D_SIZE 2\n"
            "0 0 0\n"
            "0.6 0.5 0.4\n"
            "1 1 1\n"
            "0 0 0\n"
            "1 0 0\n"
            "0 1 0\n"
            "1 1 0\n"
            "0 0 1\n"
            "1 0 1\n"
            "0 1 1\n"
            "1 1 1\n";
        FILE* f = fopen("probe.cube", "wt");
        fputs(cube, f);
        fclose(f);
        cmsHPROFILE h = cmsCreateDeviceLinkFromCubeFile("probe.cube");
        printf("  loaded: %s\n", h ? "yes" : "no");
        if (h) {
            char desc[64];
            cmsGetProfileInfoASCII(h, cmsInfoDescription, "en", "US", desc, sizeof desc);
            printf("  class %08x space %08x desc '%s'\n", cmsGetDeviceClass(h), cmsGetColorSpace(h), desc);
            cmsHTRANSFORM x = cmsCreateTransform(h, TYPE_RGB_16, NULL, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE);
            if (x) {
                for (int i = 0; i < 27; i++) {
                    unsigned short in[3] = { (unsigned short)((i % 3) * 32767), (unsigned short)(((i / 3) % 3) * 32767), (unsigned short)((i / 9) * 32767) }, out[3];
                    cmsDoTransform(x, in, out, 1);
                    printf("  %5u %5u %5u -> %5u %5u %5u\n", in[0], in[1], in[2], out[0], out[1], out[2]);
                }
                cmsDeleteTransform(x);
            } else printf("  (transform refused)\n");
            cmsCloseProfile(h);
        }
        f = fopen("probe.cube", "wt");
        fputs("LUT_IN_VIDEO_RANGE 0 1\nLUT_3D_SIZE 2\n", f);
        fclose(f);
        h = cmsCreateDeviceLinkFromCubeFile("probe.cube");
        printf("  video range: %s\n", h ? "loaded" : "refused");
        if (h) cmsCloseProfile(h);
        f = fopen("probe.cube", "wt");
        fputs("LUT_3D_SIZE 99\n0 0 0\n", f);
        fclose(f);
        h = cmsCreateDeviceLinkFromCubeFile("probe.cube");
        printf("  too big: %s\n", h ? "loaded" : "refused");
        if (h) cmsCloseProfile(h);
        remove("probe.cube");
        h = cmsCreateDeviceLinkFromCubeFile("no-such.cube");
        printf("  missing file: %s\n", h ? "loaded" : "refused");
    }
    return 0;
}
