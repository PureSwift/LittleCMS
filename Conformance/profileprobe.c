/* profileprobe.c - the profile container, against the reference
 *
 * Reads real profile bytes and compares everything the container claims
 * about them: the header fields, the tag directory, which tags are links
 * to which, and the raw bytes behind each tag.  No tag payload is
 * decoded here — a tag is an offset and a size until the tag-type layer
 * exists.
 *
 * The creation timestamp of a *new* placeholder comes from the clock and
 * so is deliberately never hashed; the timestamp read *out of a file* is,
 * because that one is in the bytes.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"   /* the date-time coders live here */

#include <math.h>
#include <unistd.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t hash_state = 1469598103934665603ULL;

static void feed(const void* bytes, size_t length)
{
    const unsigned char* p = (const unsigned char*) bytes;
    for (size_t i = 0; i < length; i++) {
        hash_state ^= p[i];
        hash_state *= 1099511628211ULL;
    }
}

/* A four-byte type signature, printed so it can never contain a NUL.
 *
 * Printing raw bytes with %c made diff treat the whole output as binary,
 * and binary mode emits no +/- lines -- so the runner extracted nothing
 * and reported agreement while the two builds disagreed.  The runner now
 * refuses that outcome, and probes do not produce it. */
static const char* type_name(const unsigned char b[4])
{
    static char out[16];
    int n = 0;
    for (int i = 0; i < 4; i++) {
        if (b[i] >= 0x20 && b[i] < 0x7F) out[n++] = (char) b[i];
        else { out[n++] = '.'; }
    }
    out[n] = 0;
    return out;
}

/* A reproducible input stream, so both builds walk the same numbers. */
static uint32_t seed = 5150;
static uint32_t next(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

/* Curve values are floats, and a NaN is a NaN — see docs/abi-audit.md. */
static void feed_float(float v)
{
    if (v != v) { feed("NaN", 3); return; }
    feed(&v, sizeof v);
}

/* Hashes a saved profile with the creation date masked out.
 *
 * A profile made by cmsCreateProfilePlaceholder stamps the clock, so its
 * saved bytes differ between two processes that ran in different
 * seconds -- which is a flaky test, not a conformance failure.  Only the
 * twelve date bytes at offset 24 are skipped; everything else, header
 * and tags alike, is still compared. */
static void feed_saved(const unsigned char* bytes, size_t length)
{
    for (size_t i = 0; i < length; i++) {
        if (i >= 24 && i < 36) continue;
        feed(&bytes[i], 1);
    }
}

static void report(const char* name)
{
    printf("%-34s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* A minimal well-formed profile, assembled here rather than read from
 * disk so that both builds see byte-identical input with no corpus
 * dependency.  Two tags deliberately share a byte range, which is how
 * the reference decides one is a link to the other. */
static unsigned char* build_profile(size_t* out_size, int tag_count,
                                    unsigned int declared_size_override)
{
    /* 128-byte header + count + 3 entries * 12 + payloads */
    size_t directory = 4 + (size_t) tag_count * 12;
    size_t payload_at = 128 + directory;
    size_t total = payload_at + 64;
    unsigned char* p = (unsigned char*) calloc(1, total);
    if (p == NULL) return NULL;

    unsigned int size = declared_size_override ? declared_size_override : (unsigned int) total;
    p[0] = (unsigned char) (size >> 24); p[1] = (unsigned char) (size >> 16);
    p[2] = (unsigned char) (size >> 8);  p[3] = (unsigned char) size;

    memcpy(p + 4, "ACMS", 4);            /* preferred CMM */
    memcpy(p + 8, "\x02\x40\x00\x00", 4); /* version 2.4 */
    memcpy(p + 12, "mntr", 4);           /* device class */
    memcpy(p + 16, "RGB ", 4);           /* data colour space */
    memcpy(p + 20, "XYZ ", 4);           /* PCS */

    /* creation date: 2019-03-07 11:22:33 */
    unsigned short date[6] = { 2019, 3, 7, 11, 22, 33 };
    for (int i = 0; i < 6; i++) {
        p[24 + i * 2] = (unsigned char) (date[i] >> 8);
        p[25 + i * 2] = (unsigned char) date[i];
    }

    memcpy(p + 36, "acsp", 4);           /* magic */
    memcpy(p + 40, "APPL", 4);           /* platform */
    memcpy(p + 44, "\x00\x00\x00\x03", 4); /* flags */
    memcpy(p + 48, "MFGR", 4);
    memcpy(p + 52, "MODL", 4);
    memcpy(p + 56, "\x00\x00\x00\x01\x00\x00\x00\x02", 8); /* attributes */
    memcpy(p + 64, "\x00\x00\x00\x01", 4); /* rendering intent */
    memcpy(p + 80, "CREA", 4);           /* creator */
    for (int i = 0; i < 16; i++) p[84 + i] = (unsigned char) (0x10 + i); /* profile ID */

    p[128 + 3] = (unsigned char) tag_count;

    /* Every tag points at the same 8 bytes: rXYZ/gXYZ/bXYZ all carry the
     * same descriptor, so the reference links the later ones to the
     * first.  cprt has a different descriptor and must NOT link. */
    static const char* names[4] = { "rXYZ", "gXYZ", "cprt", "bXYZ" };
    for (int i = 0; i < tag_count && i < 4; i++) {
        unsigned char* e = p + 132 + i * 12;
        memcpy(e, names[i], 4);
        unsigned int offset = (unsigned int) payload_at;
        unsigned int length = 20;
        e[4] = (unsigned char) (offset >> 24); e[5] = (unsigned char) (offset >> 16);
        e[6] = (unsigned char) (offset >> 8);  e[7] = (unsigned char) offset;
        e[8] = (unsigned char) (length >> 24); e[9] = (unsigned char) (length >> 16);
        e[10] = (unsigned char) (length >> 8); e[11] = (unsigned char) length;
    }

    memcpy(p + payload_at, "XYZ \0\0\0\0", 8);
    for (int i = 8; i < 20; i++) p[payload_at + i] = (unsigned char) (i * 7);

    *out_size = total;
    return p;
}

/* `dated` says whether the creation timestamp came out of a file and is
 * therefore part of the answer.  A profile built by
 * cmsCreateProfilePlaceholder stamps the clock instead, so printing it
 * makes the probe fail whenever the two builds happen to run in
 * different seconds -- which is a flaky test, not a divergence. */
static void inspect(cmsHPROFILE h, const char* label, int dated)
{
    if (h == NULL) { printf("%-34s refused\n", label); return; }

    printf("%-34s class %08x space %08x pcs %08x\n", label,
           (unsigned) cmsGetDeviceClass(h),
           (unsigned) cmsGetColorSpace(h),
           (unsigned) cmsGetPCS(h));
    printf("  version %.4f encoded %08x intent %u flags %08x\n",
           cmsGetProfileVersion(h),
           (unsigned) cmsGetEncodedICCversion(h),
           cmsGetHeaderRenderingIntent(h),
           (unsigned) cmsGetHeaderFlags(h));
    printf("  cmm %08x creator %08x mfg %08x model %08x\n",
           (unsigned) cmsGetHeaderCMM(h), (unsigned) cmsGetHeaderCreator(h),
           (unsigned) cmsGetHeaderManufacturer(h), (unsigned) cmsGetHeaderModel(h));

    cmsUInt64Number attributes = 0;
    cmsGetHeaderAttributes(h, &attributes);
    feed(&attributes, sizeof attributes);

    cmsUInt8Number id[16];
    memset(id, 0, sizeof id);
    cmsGetHeaderProfileID(h, id);
    feed(id, sizeof id);

    /* The date came out of the file, so it is part of the answer. */
    struct tm created;
    memset(&created, 0, sizeof created);
    if (dated && cmsGetHeaderCreationDateTime(h, &created)) {
        printf("  created %04d-%02d-%02d %02d:%02d:%02d wday %d yday %d isdst %d\n",
               created.tm_year + 1900, created.tm_mon + 1, created.tm_mday,
               created.tm_hour, created.tm_min, created.tm_sec,
               created.tm_wday, created.tm_yday, created.tm_isdst);
    }

    cmsInt32Number n = cmsGetTagCount(h);
    printf("  tags %d\n", (int) n);
    for (cmsInt32Number i = 0; i < n; i++) {
        cmsTagSignature sig = cmsGetTagSignature(h, (cmsUInt32Number) i);
        cmsUInt32Number offset = 0, size = 0;
        cmsBool ok = cmsGetTagOffsetAndSize(h, (cmsUInt32Number) i, &offset, &size);
        printf("    %d %08x at %u size %u ok %d linked %08x present %d\n",
               (int) i, (unsigned) sig, offset, size, ok,
               (unsigned) cmsTagLinkedTo(h, sig), cmsIsTag(h, sig));

        /* The raw bytes, through the buffer a client would pass. */
        unsigned char buffer[32];
        memset(buffer, 0, sizeof buffer);
        cmsUInt32Number got = cmsReadRawTag(h, sig, buffer, sizeof buffer);
        printf("      raw %u bytes\n", got);
        feed(buffer, sizeof buffer);
    }

    /* Reading one past the end, which the reference permits. */
    printf("  one past end %08x\n",
           (unsigned) cmsGetTagSignature(h, (cmsUInt32Number) n));
    printf("  absent tag present %d linked %08x raw %u\n",
           cmsIsTag(h, cmsSigVcgtTag),
           (unsigned) cmsTagLinkedTo(h, cmsSigVcgtTag),
           cmsReadRawTag(h, cmsSigVcgtTag, NULL, 0));

    report(label);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    /* -- a profile with linked tags ---------------------------------------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 4, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);
        inspect(h, "four tags, three linkable", 1);
        printf("closed %d\n", cmsCloseProfile(h));
        free(bytes);
    }

    /* -- asking for the size without a buffer ------------------------------ */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 2, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);
        printf("size query %u\n", cmsReadRawTag(h, cmsSigRedColorantTag, NULL, 0));
        /* A short buffer truncates rather than failing. */
        unsigned char small[6];
        memset(small, 0, sizeof small);
        printf("short read %u\n",
               cmsReadRawTag(h, cmsSigRedColorantTag, small, sizeof small));
        feed(small, sizeof small);
        /* A buffer of zero length with a non-null pointer is refused. */
        printf("zero-length %u\n", cmsReadRawTag(h, cmsSigRedColorantTag, small, 0));
        report("raw tag reads");
        cmsCloseProfile(h);
        free(bytes);
    }

    /* -- a declared size smaller than the file drops the tags -------------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 4, 140);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);
        inspect(h, "declared size clips the tags", 1);
        cmsCloseProfile(h);
        free(bytes);
    }

    /* -- refusals ---------------------------------------------------------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 2, 0);

        memcpy(bytes + 36, "junk", 4);
        printf("bad magic -> %s\n",
               cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size) ? "opened" : "refused");
        memcpy(bytes + 36, "acsp", 4);

        memcpy(bytes + 12, "zzzz", 4);
        printf("bad class -> %s\n",
               cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size) ? "opened" : "refused");
        memcpy(bytes + 12, "mntr", 4);

        memcpy(bytes + 8, "\x06\x00\x00\x00", 4);
        printf("version 6 -> %s\n",
               cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size) ? "opened" : "refused");
        memcpy(bytes + 8, "\x02\x40\x00\x00", 4);

        /* Two tags with the same signature. */
        memcpy(bytes + 132 + 12, "rXYZ", 4);
        printf("duplicate tag -> %s\n",
               cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size) ? "opened" : "refused");

        printf("truncated -> %s\n",
               cmsOpenProfileFromMem(bytes, 64) ? "opened" : "refused");
        printf("empty -> %s\n", cmsOpenProfileFromMem(bytes, 0) ? "opened" : "refused");
        free(bytes);
    }

    /* -- the version field is clamped, not rejected ------------------------ */
    {
        static const unsigned char versions[8][4] = {
            { 0x02, 0x40, 0x00, 0x00 },
            { 0x02, 0x4F, 0xFF, 0xFF },   /* low nibble over 9 */
            { 0x02, 0xF0, 0x00, 0x00 },   /* high nibble over 9 */
            { 0x04, 0x30, 0xAB, 0xCD },   /* reserved bytes discarded */
            { 0x00, 0x00, 0x00, 0x00 },
            { 0x04, 0x00, 0x00, 0x00 },
            { 0x02, 0x11, 0x00, 0x00 },
            { 0x03, 0x99, 0x00, 0x00 }
        };
        for (int i = 0; i < 8; i++) {
            size_t size = 0;
            unsigned char* bytes = build_profile(&size, 1, 0);
            memcpy(bytes + 8, versions[i], 4);
            cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);
            if (h == NULL) { printf("version %d refused\n", i); }
            else {
                printf("version %d -> %.6f encoded %08x\n", i,
                       cmsGetProfileVersion(h), (unsigned) cmsGetEncodedICCversion(h));
                cmsCloseProfile(h);
            }
            free(bytes);
        }
    }

    /* -- setting the version back, which must round-trip ------------------- */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        printf("placeholder %d default encoded %08x\n",
               h != NULL, (unsigned) cmsGetEncodedICCversion(h));
        printf("default class %08x cmm %08x creator %08x\n",
               (unsigned) cmsGetDeviceClass(h),
               (unsigned) cmsGetHeaderCMM(h),
               (unsigned) cmsGetHeaderCreator(h));

        static const double wanted[] = { 2.0, 2.1, 2.2, 2.4, 4.0, 4.3, 4.4, 5.0, 0.0, 2.15 };
        for (size_t i = 0; i < sizeof wanted / sizeof wanted[0]; i++) {
            cmsSetProfileVersion(h, wanted[i]);
            printf("  set %.2f -> encoded %08x reads %.6f\n",
                   wanted[i], (unsigned) cmsGetEncodedICCversion(h),
                   cmsGetProfileVersion(h));
        }

        /* The header setters, read back. */
        cmsSetDeviceClass(h, cmsSigOutputClass);
        cmsSetColorSpace(h, cmsSigCmykData);
        cmsSetPCS(h, cmsSigLabData);
        cmsSetHeaderRenderingIntent(h, INTENT_SATURATION);
        cmsSetHeaderFlags(h, 0xDEADBEEF);
        cmsSetHeaderManufacturer(h, 0x41424344);
        cmsSetHeaderModel(h, 0x45464748);
        cmsSetHeaderAttributes(h, 0x0123456789ABCDEFULL);
        cmsUInt8Number id[16];
        for (int i = 0; i < 16; i++) id[i] = (cmsUInt8Number) (200 - i);
        cmsSetHeaderProfileID(h, id);
        cmsSetEncodedICCversion(h, 0x02300000);

        inspect(h, "placeholder after setting", 0);
        cmsCloseProfile(h);
    }

    /* -- channel counts ----------------------------------------------------- */
    {
        static const cmsColorSpaceSignature spaces[] = {
            cmsSigXYZData, cmsSigLabData, cmsSigLuvData, cmsSigYCbCrData, cmsSigYxyData,
            cmsSigRgbData, cmsSigGrayData, cmsSigHsvData, cmsSigHlsData, cmsSigCmykData,
            cmsSigCmyData, cmsSigMCH1Data, cmsSigMCH4Data, cmsSigMCHFData,
            cmsSig1colorData, cmsSig15colorData, cmsSigLuvKData,
            cmsSigNamedData, (cmsColorSpaceSignature) 0
        };
        for (size_t i = 0; i < sizeof spaces / sizeof spaces[0]; i++)
            printf("channels %08x -> %d\n", (unsigned) spaces[i],
                   (int) cmsChannelsOfColorSpace(spaces[i]));
    }

    /* -- the date-time field, both directions ------------------------------- */
    {
        static const unsigned short dates[5][6] = {
            { 2026, 8, 17, 13, 45, 59 },
            { 1900, 1, 1, 0, 0, 0 },
            { 2000, 12, 31, 23, 59, 60 },
            { 0, 0, 0, 0, 0, 0 },
            { 65535, 65535, 65535, 65535, 65535, 65535 }
        };
        for (int i = 0; i < 5; i++) {
            cmsDateTimeNumber encoded;
            struct tm decoded;
            memset(&encoded, 0, sizeof encoded);
            memset(&decoded, 0, sizeof decoded);

            decoded.tm_year = dates[i][0] - 1900;
            decoded.tm_mon = dates[i][1] - 1;
            decoded.tm_mday = dates[i][2];
            decoded.tm_hour = dates[i][3];
            decoded.tm_min = dates[i][4];
            decoded.tm_sec = dates[i][5];

            _cmsEncodeDateTimeNumber(&encoded, &decoded);
            feed(&encoded, sizeof encoded);

            struct tm back;
            memset(&back, 0, sizeof back);
            _cmsDecodeDateTimeNumber(&encoded, &back);
            printf("date %d -> %d-%d-%d %d:%d:%d wday %d yday %d isdst %d\n", i,
                   back.tm_year, back.tm_mon, back.tm_mday,
                   back.tm_hour, back.tm_min, back.tm_sec,
                   back.tm_wday, back.tm_yday, back.tm_isdst);
        }
        report("date-time round trips");
    }

    /* -- opening from a file, and the write mode that reads nothing --------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 3, 0);
        /* Named after the process, so that two probes running at once
         * -- ctest -j, or the determinism re-run -- cannot collide over
         * a shared file. */
        char path[64];
        snprintf(path, sizeof path, "profileprobe.%ld.tmp.icc", (long) getpid());
        FILE* f = fopen(path, "wb");
        if (f != NULL) {
            fwrite(bytes, 1, size, f);
            fclose(f);

            cmsHPROFILE h = cmsOpenProfileFromFile(path, "r");
            inspect(h, "from file", 1);
            cmsCloseProfile(h);

            /* Opened for writing there is no header to read, so the
             * container carries the placeholder's defaults. */
            cmsHPROFILE w = cmsOpenProfileFromFile(path, "w");
            printf("write mode opened %d tags %d class %08x\n",
                   w != NULL, (int) cmsGetTagCount(w),
                   (unsigned) cmsGetDeviceClass(w));
            /* Deliberately not closed: closing a write-mode profile
             * saves it, and saving is the next commit's claim, not this
             * one's.  Leaking it here keeps the probe measuring only
             * what has been ported. */

            printf("missing file -> %s\n",
                   cmsOpenProfileFromFile("no-such-profile.icc", "r") ? "opened" : "refused");
            remove(path);
        }
        free(bytes);
    }

    /* -- saving: the bytes that come back out ------------------------------ */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 4, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);

        /* Asking how much room a save would need must not write. */
        cmsUInt32Number needed = 0;
        printf("size query %d needed %u\n", cmsSaveProfileToMem(h, NULL, &needed), needed);

        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        printf("saved %d wrote %u\n", cmsSaveProfileToMem(h, out, &room), room);
        feed(out, needed);
        report("saved bytes");

        /* Saving must leave the profile exactly as it was, so a second
         * save of the same profile is the same bytes. */
        cmsUInt32Number again = needed;
        unsigned char* twice = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsSaveProfileToMem(h, twice, &again);
        printf("second save identical %d\n",
               needed && memcmp(out, twice, needed) == 0);

        /* And the saved bytes must reopen as the same profile. */
        cmsHPROFILE reopened = cmsOpenProfileFromMem(out, needed);
        inspect(reopened, "reopened after save", 1);
        cmsCloseProfile(reopened);

        /* A buffer too small to hold it. */
        cmsUInt32Number tiny = 8;
        unsigned char small[8];
        printf("save into 8 bytes -> %d\n", cmsSaveProfileToMem(h, small, &tiny));

        free(twice);
        free(out);
        cmsCloseProfile(h);
        free(bytes);
    }

    /* -- the profile identifier -------------------------------------------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 3, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);

        cmsUInt8Number before[16], after[16];
        cmsGetHeaderProfileID(h, before);
        feed(before, sizeof before);

        printf("computed id %d\n", cmsMD5computeID(h));
        cmsGetHeaderProfileID(h, after);
        feed(after, sizeof after);
        printf("id changed %d\n", memcmp(before, after, 16) != 0);

        /* The identifier ignores the rendering intent, the flags and
         * the previous identifier, so changing those must not change it. */
        cmsSetHeaderRenderingIntent(h, INTENT_SATURATION);
        cmsSetHeaderFlags(h, 0xFFFFFFFF);
        cmsMD5computeID(h);
        cmsUInt8Number third[16];
        cmsGetHeaderProfileID(h, third);
        printf("id stable under intent and flags %d\n",
               memcmp(after, third, 16) == 0);

        /* But those fields are still there afterwards. */
        printf("intent %u flags %08x survive\n",
               cmsGetHeaderRenderingIntent(h), (unsigned) cmsGetHeaderFlags(h));

        report("profile identifier");
        cmsCloseProfile(h);
        free(bytes);
    }

    /* -- saving through a file, and the write-mode close that saves --------- */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 3, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);

        char path[64];
        snprintf(path, sizeof path, "profileprobe.%ld.save.icc", (long) getpid());
        printf("save to file %d\n", cmsSaveProfileToFile(h, path));

        cmsHPROFILE back = cmsOpenProfileFromFile(path, "r");
        inspect(back, "read back from file", 1);
        cmsCloseProfile(back);

        /* A path that cannot be written. */
        printf("save to bad path %d\n",
               cmsSaveProfileToFile(h, "no-such-directory/out.icc"));

        cmsCloseProfile(h);
        remove(path);
        free(bytes);
    }

    /* -- cooked tags: reading a payload, not a byte range ------------------ */
    {
        size_t size = 0;
        unsigned char* bytes = build_profile(&size, 4, 0);
        cmsHPROFILE h = cmsOpenProfileFromMem(bytes, (cmsUInt32Number) size);

        /* rXYZ carries an XYZ, which the tag layer turns into a struct.
         * The pointer belongs to the profile: reading twice must give
         * the same pointer, not two copies. */
        cmsCIEXYZ* first = (cmsCIEXYZ*) cmsReadTag(h, cmsSigRedColorantTag);
        cmsCIEXYZ* again = (cmsCIEXYZ*) cmsReadTag(h, cmsSigRedColorantTag);
        printf("read %d cached %d\n", first != NULL, first == again);
        if (first != NULL) {
            printf("  XYZ %.8f %.8f %.8f\n", first->X, first->Y, first->Z);
            feed(first, sizeof *first);
        }

        /* A linked tag reads through to what it links to, and lands on
         * the same object. */
        cmsCIEXYZ* linked = (cmsCIEXYZ*) cmsReadTag(h, cmsSigGreenColorantTag);
        printf("linked reads same object %d\n", linked == first);

        /* cprt is text over the same bytes, and its descriptor does not
         * allow XYZ — so it must refuse rather than reinterpret. */
        void* text = cmsReadTag(h, cmsSigCopyrightTag);
        printf("mismatched type -> %s\n", text ? "read" : "refused");

        /* A tag the profile does not have. */
        printf("absent tag -> %s\n",
               cmsReadTag(h, cmsSigLuminanceTag) ? "read" : "refused");

        report("cooked reads");
        cmsCloseProfile(h);
        free(bytes);
    }

    /* -- writing tags, and what comes back --------------------------------- */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        cmsSetColorSpace(h, cmsSigRgbData);
        cmsSetPCS(h, cmsSigXYZData);

        cmsCIEXYZ white = { 0.9642, 1.0, 0.8249 };
        printf("write XYZ %d\n", cmsWriteTag(h, cmsSigMediaWhitePointTag, &white));

        /* The profile keeps a copy: changing the caller's struct
         * afterwards must not change the tag. */
        white.X = 42.0;
        cmsCIEXYZ* stored = (cmsCIEXYZ*) cmsReadTag(h, cmsSigMediaWhitePointTag);
        printf("copied not aliased %d\n", stored && stored->X != 42.0);
        if (stored) feed(stored, sizeof *stored);

        /* A chromatic adaptation matrix: nine numbers, so the element
         * count in the descriptor is what decides how many are kept. */
        cmsFloat64Number chad[9] = {
            1.0, 0.1, 0.2, 0.3, 1.1, 0.4, 0.5, 0.6, 1.2
        };
        printf("write chad %d\n", cmsWriteTag(h, cmsSigChromaticAdaptationTag, chad));

        /* Text, through the multi-localized container the tag layer
         * hands back whichever text type was used. */
        cmsMLU* mlu = cmsMLUalloc(NULL, 1);
        cmsMLUsetASCII(mlu, cmsNoLanguage, cmsNoCountry, "a copyright notice");
        printf("write text %d\n", cmsWriteTag(h, cmsSigCharTargetTag, mlu));
        cmsMLUfree(mlu);

        /* A date. */
        struct tm when;
        memset(&when, 0, sizeof when);
        when.tm_year = 2026 - 1900; when.tm_mon = 7; when.tm_mday = 17;
        when.tm_hour = 9; when.tm_min = 30; when.tm_sec = 15;
        printf("write date %d\n", cmsWriteTag(h, cmsSigCalibrationDateTimeTag, &when));

        /* A signature. */
        cmsSignature technology = cmsSigCRTDisplay;
        printf("write signature %d\n", cmsWriteTag(h, cmsSigTechnologyTag, &technology));

        /* A tag the library does not know refuses. */
        printf("unknown tag -> %d\n",
               cmsWriteTag(h, (cmsTagSignature) 0x7A7A7A7A, &white));

        printf("tags now %d\n", (int) cmsGetTagCount(h));

        /* Save it, reopen it, and read everything back — which only
         * works if what was written is what the readers expect. */
        cmsUInt32Number needed = 0;
        cmsSaveProfileToMem(h, NULL, &needed);
        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        printf("saved %d bytes %u\n", cmsSaveProfileToMem(h, out, &room), needed);
        feed_saved(out, needed);
        report("written profile bytes");

        cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
        printf("reopened %d tags %d\n", back != NULL, (int) cmsGetTagCount(back));

        cmsCIEXYZ* wp = (cmsCIEXYZ*) cmsReadTag(back, cmsSigMediaWhitePointTag);
        if (wp) printf("  white %.8f %.8f %.8f\n", wp->X, wp->Y, wp->Z);

        cmsFloat64Number* m = (cmsFloat64Number*) cmsReadTag(back, cmsSigChromaticAdaptationTag);
        if (m) { for (int i = 0; i < 9; i++) feed(&m[i], sizeof m[i]); }

        cmsMLU* got = (cmsMLU*) cmsReadTag(back, cmsSigCharTargetTag);
        if (got) {
            char buffer[64];
            memset(buffer, 0, sizeof buffer);
            cmsMLUgetASCII(got, cmsNoLanguage, cmsNoCountry, buffer, sizeof buffer);
            printf("  text '%s'\n", buffer);
        }

        struct tm* date = (struct tm*) cmsReadTag(back, cmsSigCalibrationDateTimeTag);
        if (date)
            printf("  date %04d-%02d-%02d %02d:%02d:%02d\n",
                   date->tm_year + 1900, date->tm_mon + 1, date->tm_mday,
                   date->tm_hour, date->tm_min, date->tm_sec);

        cmsSignature* tech = (cmsSignature*) cmsReadTag(back, cmsSigTechnologyTag);
        if (tech) printf("  technology %08x\n", (unsigned) *tech);

        report("round-tripped tags");
        cmsCloseProfile(back);
        free(out);
        cmsCloseProfile(h);
    }

    /* -- deleting, relinking, and raw storage ------------------------------- */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        cmsCIEXYZ v = { 0.5, 0.6, 0.7 };
        cmsWriteTag(h, cmsSigMediaWhitePointTag, &v);
        cmsWriteTag(h, cmsSigLuminanceTag, &v);
        printf("two tags %d\n", (int) cmsGetTagCount(h));

        /* Deleting keeps the slot but zeroes its name. */
        printf("delete %d, count %d, present %d\n",
               cmsWriteTag(h, cmsSigLuminanceTag, NULL),
               (int) cmsGetTagCount(h), cmsIsTag(h, cmsSigLuminanceTag));
        printf("delete absent -> %d\n", cmsWriteTag(h, cmsSigGamutTag, NULL));

        /* Linking, then reading through the link. */
        printf("link %d\n", cmsLinkTag(h, cmsSigMediaBlackPointTag, cmsSigMediaWhitePointTag));
        printf("linked to %08x reads %d\n",
               (unsigned) cmsTagLinkedTo(h, cmsSigMediaBlackPointTag),
               cmsReadTag(h, cmsSigMediaBlackPointTag) != NULL);

        /* Raw bytes: stored as given, and written out untouched. */
        unsigned char blob[24];
        for (int i = 0; i < 24; i++) blob[i] = (unsigned char) (i * 11);
        memcpy(blob, "XYZ ", 4);
        printf("write raw %d\n", cmsWriteRawTag(h, cmsSigGamutTag, blob, sizeof blob));

        unsigned char readback[32];
        memset(readback, 0, sizeof readback);
        printf("raw back %u\n", cmsReadRawTag(h, cmsSigGamutTag, readback, sizeof readback));
        feed(readback, sizeof readback);

        /* Writing a cooked tag over a raw one.  cmsWriteTag guards
         * against this with an "already saved as RAW" error -- but the
         * guard is unreachable: _cmsNewTag runs first, and freeing the
         * old value is what clears the raw flag.  So this succeeds, and
         * the tag stops being raw. */
        unsigned char lum[24];
        memcpy(lum, "XYZ \0\0\0\0", 8);
        for (int i = 8; i < 24; i++) lum[i] = (unsigned char) i;
        cmsWriteRawTag(h, cmsSigLuminanceTag, lum, sizeof lum);
        printf("cooked over raw -> %d\n", cmsWriteTag(h, cmsSigLuminanceTag, &v));
        printf("  now reads cooked %d\n",
               cmsReadTag(h, cmsSigLuminanceTag) != NULL);

        cmsUInt32Number needed = 0;
        cmsSaveProfileToMem(h, NULL, &needed);
        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        cmsSaveProfileToMem(h, out, &room);
        feed_saved(out, needed);
        printf("saved with a hole, %u bytes\n", needed);
        report("deleted, linked and raw");

        /* Left until last, deliberately.  Asking for a raw-stored tag
         * as a cooked one is refused -- but the refusal path in the
         * reference frees the stored bytes while leaving the slot
         * marked raw, so a later cmsReadRawTag falls through to the
         * on-disk path and dereferences an IO handler this profile has
         * never had.  Ours returns zero there.  A crash is not a
         * behaviour to reproduce, so the probe asks the question after
         * everything that would be poisoned by the answer.  Recorded in
         * docs/abi-audit.md. */
        printf("raw as cooked -> %s\n",
               cmsReadTag(h, cmsSigGamutTag) ? "read" : "refused");

        free(out);
        cmsCloseProfile(h);
    }

    /* -- curves, and the version that decides how they are stored --------- */
    {
        /* A gamma keeps its exponent; a table stays a table; and on a
         * version 4 profile a single ICC-form segment goes out
         * parametrically instead. */
        static const double versions[2] = { 2.4, 4.3 };
        for (int v = 0; v < 2; v++) {
            cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
            cmsSetProfileVersion(h, versions[v]);
            cmsSetColorSpace(h, cmsSigRgbData);

            cmsToneCurve* gamma = cmsBuildGamma(NULL, 2.2);
            cmsToneCurve* sigmoid = cmsBuildParametricToneCurve(NULL, 4,
                (cmsFloat64Number[]) { 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 });
            cmsUInt16Number table[32];
            for (int i = 0; i < 32; i++) table[i] = (cmsUInt16Number) (i * 2114);
            cmsToneCurve* tabulated = cmsBuildTabulatedToneCurve16(NULL, 32, table);

            printf("v%.1f write curves %d %d %d\n", versions[v],
                   cmsWriteTag(h, cmsSigRedTRCTag, gamma),
                   cmsWriteTag(h, cmsSigGreenTRCTag, sigmoid),
                   cmsWriteTag(h, cmsSigBlueTRCTag, tabulated));

            /* Text, which the same version rule sends to a different
             * type: flat before 4, multi-localized from 4 on. */
            cmsMLU* mlu = cmsMLUalloc(NULL, 2);
            cmsMLUsetASCII(mlu, "en", "US", "a description");
            cmsMLUsetASCII(mlu, "fr", "FR", "une description");
            printf("  write desc %d\n", cmsWriteTag(h, cmsSigProfileDescriptionTag, mlu));
            cmsMLUfree(mlu);

            cmsUInt32Number needed = 0;
            cmsSaveProfileToMem(h, NULL, &needed);
            unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
            cmsUInt32Number room = needed;
            cmsSaveProfileToMem(h, out, &room);
            feed_saved(out, needed);
            printf("  saved %u bytes\n", needed);

            cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
            printf("  reopened %d\n", back != NULL);

            /* The stored type is visible in the tag's first four bytes,
             * which is how a client tells parametric from tabulated. */
            static const cmsTagSignature trcs[3] = {
                cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag
            };
            for (int i = 0; i < 3; i++) {
                unsigned char base[4] = { 0, 0, 0, 0 };
                cmsReadRawTag(back, trcs[i], base, sizeof base);
                cmsToneCurve* got = (cmsToneCurve*) cmsReadTag(back, trcs[i]);
                printf("    trc %d type %s read %d\n", i,
                       type_name(base), got != NULL);
                if (got) {
                    for (int k = 0; k <= 16; k++) {
                        cmsFloat32Number x = (cmsFloat32Number) k / 16.0f;
                        feed_float(cmsEvalToneCurveFloat(got, x));
                    }
                    printf("      linear %d estimated gamma %.4f\n",
                           cmsIsToneCurveLinear(got),
                           cmsEstimateGamma(got, 0.01));
                }
            }

            unsigned char descbase[4] = { 0, 0, 0, 0 };
            cmsReadRawTag(back, cmsSigProfileDescriptionTag, descbase, sizeof descbase);
            cmsMLU* gotmlu = (cmsMLU*) cmsReadTag(back, cmsSigProfileDescriptionTag);
            printf("    desc type %s read %d translations %u\n",
                   type_name(descbase), gotmlu != NULL,
                   gotmlu ? cmsMLUtranslationsCount(gotmlu) : 0);
            if (gotmlu) {
                char buffer[64];
                memset(buffer, 0, sizeof buffer);
                cmsMLUgetASCII(gotmlu, "en", "US", buffer, sizeof buffer);
                printf("      en-US '%s'\n", buffer);
                memset(buffer, 0, sizeof buffer);
                cmsMLUgetASCII(gotmlu, "fr", "FR", buffer, sizeof buffer);
                printf("      fr-FR '%s'\n", buffer);
            }

            report(versions[v] < 4.0 ? "v2 curves and text" : "v4 curves and text");

            /* Saving what was just read must reproduce the same bytes:
             * a profile that round-trips through the tag layer twice is
             * the strongest thing this probe can ask. */
            cmsUInt32Number again = 0;
            cmsSaveProfileToMem(back, NULL, &again);
            unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
            cmsUInt32Number room2 = again;
            cmsSaveProfileToMem(back, twice, &room2);
            printf("  re-saved %u bytes, identical %d\n", again,
                   again == needed && memcmp(out, twice, again) == 0);

            free(twice);
            cmsCloseProfile(back);
            free(out);
            cmsCloseProfile(h);
            cmsFreeToneCurve(gamma);
            cmsFreeToneCurve(sigmoid);
            cmsFreeToneCurve(tabulated);
        }
    }

    /* -- the 8-bit LUT type ------------------------------------------------ */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        cmsSetProfileVersion(h, 2.4);          /* v2 chooses mft1 or mft2 */
        cmsSetColorSpace(h, cmsSigRgbData);
        cmsSetPCS(h, cmsSigLabData);

        /* A full four-stage pipeline: matrix, input curves, CLUT,
         * output curves — the shape mft1 can hold and no other. */
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        static const cmsFloat64Number matrix[9] = {
            0.9, 0.05, 0.05,  0.1, 0.8, 0.1,  0.05, 0.15, 0.8
        };
        cmsPipelineInsertStage(lut, cmsAT_END,
                               cmsStageAllocMatrix(NULL, 3, 3, matrix, NULL));

        cmsToneCurve* pre[3];
        cmsUInt16Number ramp[256];
        for (int i = 0; i < 256; i++) ramp[i] = (cmsUInt16Number) (i * 257);
        for (int i = 0; i < 3; i++) pre[i] = cmsBuildTabulatedToneCurve16(NULL, 256, ramp);
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, pre));
        for (int i = 0; i < 3; i++) cmsFreeToneCurve(pre[i]);

        cmsUInt16Number* grid = (cmsUInt16Number*) calloc(9 * 9 * 9 * 3, sizeof(cmsUInt16Number));
        for (int i = 0; i < 9 * 9 * 9 * 3; i++)
            grid[i] = (cmsUInt16Number) ((i * 7919) & 0xFFFF);
        cmsPipelineInsertStage(lut, cmsAT_END,
                               cmsStageAllocCLut16bit(NULL, 9, 3, 3, grid));
        free(grid);

        cmsToneCurve* post[3];
        for (int i = 0; i < 3; i++) post[i] = cmsBuildTabulatedToneCurve16(NULL, 256, ramp);
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, post));
        for (int i = 0; i < 3; i++) cmsFreeToneCurve(post[i]);

        /* Marked to be stored in eight bits, which is what sends it to
         * mft1 rather than mft2. */
        cmsPipelineSetSaveAs8bitsFlag(lut, TRUE);
        printf("lut8 write %d\n", cmsWriteTag(h, cmsSigAToB0Tag, lut));
        cmsPipelineFree(lut);

        cmsUInt32Number needed = 0;
        cmsSaveProfileToMem(h, NULL, &needed);
        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        cmsSaveProfileToMem(h, out, &room);
        feed_saved(out, needed);
        printf("lut8 saved %u bytes\n", needed);
        report("lut8 profile bytes");

        cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
        unsigned char base[4] = { 0, 0, 0, 0 };
        cmsReadRawTag(back, cmsSigAToB0Tag, base, sizeof base);
        cmsPipeline* got = (cmsPipeline*) cmsReadTag(back, cmsSigAToB0Tag);
        printf("lut8 type %s read %d\n", type_name(base), got != NULL);
        if (got) {
            printf("  %u->%u stages %u\n",
                   cmsPipelineInputChannels(got), cmsPipelineOutputChannels(got),
                   cmsPipelineStageCount(got));
            for (cmsStage* st = cmsPipelineGetPtrToFirstStage(got); st; st = cmsStageNext(st))
                printf("    stage %08x %u->%u\n", (unsigned) cmsStageType(st),
                       cmsStageInputChannels(st), cmsStageOutputChannels(st));

            /* Evaluating it is the point: the bytes only matter if the
             * pipeline they rebuild computes the same colours. */
            seed = 5150;
            for (int trial = 0; trial < 200; trial++) {
                cmsFloat32Number in[4], fout[4];
                cmsUInt16Number win[4], wout[4];
                for (int i = 0; i < 3; i++) {
                    in[i] = (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
                    win[i] = (cmsUInt16Number) (next() & 0xFFFF);
                }
                memset(fout, 0, sizeof fout);
                cmsPipelineEvalFloat(in, fout, got);
                for (int i = 0; i < 3; i++) feed_float(fout[i]);
                memset(wout, 0, sizeof wout);
                cmsPipelineEval16(win, wout, got);
                for (int i = 0; i < 3; i++) feed(&wout[i], sizeof wout[i]);
            }
            report("lut8 evaluated");
        }

        /* Re-saving what was read must reproduce the same bytes. */
        cmsUInt32Number again = 0;
        cmsSaveProfileToMem(back, NULL, &again);
        unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
        cmsUInt32Number room2 = again;
        cmsSaveProfileToMem(back, twice, &room2);
        printf("lut8 re-saved %u identical %d\n", again,
               again == needed && memcmp(out, twice, again) == 0);

        free(twice);
        cmsCloseProfile(back);
        free(out);
        cmsCloseProfile(h);
    }

    /* -- the v4 LUT types --------------------------------------------------- */
    {
        /* mAB and mBA store five optional elements at their own offsets,
         * so the shapes that can be written are exactly four.  Each is
         * built, written, read back and evaluated. */
        struct { const char* name; int shape; int a2b; } cases[] = {
            { "B only",              1, 1 },
            { "M matrix B",          2, 1 },
            { "A CLUT B",            3, 1 },
            { "A CLUT M matrix B",   4, 1 },
            { "B only (BtoA)",       1, 0 },
            { "B matrix M",          2, 0 },
            { "B CLUT A",            3, 0 },
            { "B matrix M CLUT A",   4, 0 },
        };

        for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) {
            cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
            cmsSetProfileVersion(h, 4.3);      /* v4 chooses mAB / mBA */
            cmsSetColorSpace(h, cmsSigRgbData);
            cmsSetPCS(h, cmsSigLabData);

            cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
            static const cmsFloat64Number mat[9] = {
                1.1, 0.05, 0.0,  0.0, 0.9, 0.05,  0.05, 0.0, 1.05
            };
            static const cmsFloat64Number off[3] = { 0.01, -0.02, 0.03 };

            /* A granular grid, which only these types can hold. */
            static const cmsUInt32Number points[3] = { 5, 6, 7 };
            cmsUInt16Number* grid = NULL;
            cmsStage* clutStage = NULL;
            if (cases[k].shape >= 3) {
                grid = (cmsUInt16Number*) calloc(5 * 6 * 7 * 3, sizeof(cmsUInt16Number));
                for (int i = 0; i < 5 * 6 * 7 * 3; i++)
                    grid[i] = (cmsUInt16Number) ((i * 5077) & 0xFFFF);
                clutStage = cmsStageAllocCLut16bitGranular(NULL, points, 3, 3, grid);
            }

            cmsToneCurve* g22[3];
            for (int i = 0; i < 3; i++) g22[i] = cmsBuildGamma(NULL, 2.2 - 0.1 * i);

            if (cases[k].a2b) {
                if (cases[k].shape == 1) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                } else if (cases[k].shape == 2) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, mat, off));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                } else if (cases[k].shape == 3) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, clutStage);
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                } else {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, clutStage);
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, mat, off));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                }
            } else {
                if (cases[k].shape == 1) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                } else if (cases[k].shape == 2) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, mat, off));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                } else if (cases[k].shape == 3) {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, clutStage);
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                } else {
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, mat, off));
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
                    cmsPipelineInsertStage(lut, cmsAT_END, clutStage);
                    cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, g22));
                }
            }
            for (int i = 0; i < 3; i++) cmsFreeToneCurve(g22[i]);
            free(grid);

            cmsTagSignature tag = cases[k].a2b ? cmsSigAToB0Tag : cmsSigBToA0Tag;
            printf("%-20s write %d\n", cases[k].name, cmsWriteTag(h, tag, lut));
            cmsPipelineFree(lut);

            cmsUInt32Number needed = 0;
            cmsSaveProfileToMem(h, NULL, &needed);
            unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
            cmsUInt32Number room = needed;
            cmsSaveProfileToMem(h, out, &room);
            feed_saved(out, needed);
            printf("  saved %u\n", needed);

            cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
            unsigned char base[4] = { 0, 0, 0, 0 };
            cmsReadRawTag(back, tag, base, sizeof base);
            cmsPipeline* got = (cmsPipeline*) cmsReadTag(back, tag);
            printf("  type %s read %d stages %u\n", type_name(base),
                   got != NULL, got ? cmsPipelineStageCount(got) : 0);

            if (got) {
                for (cmsStage* st = cmsPipelineGetPtrToFirstStage(got); st; st = cmsStageNext(st))
                    printf("    %08x %u->%u\n", (unsigned) cmsStageType(st),
                           cmsStageInputChannels(st), cmsStageOutputChannels(st));
                seed = 909;
                for (int trial = 0; trial < 120; trial++) {
                    cmsFloat32Number in[4], fout[4];
                    for (int i = 0; i < 3; i++)
                        in[i] = (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
                    memset(fout, 0, sizeof fout);
                    cmsPipelineEvalFloat(in, fout, got);
                    for (int i = 0; i < 3; i++) feed_float(fout[i]);
                }
            }
            report(cases[k].name);

            /* And back out again, which exercises the writer on a
             * pipeline the reader built rather than one we assembled. */
            cmsUInt32Number again = 0;
            cmsSaveProfileToMem(back, NULL, &again);
            unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
            cmsUInt32Number room2 = again;
            cmsSaveProfileToMem(back, twice, &room2);
            printf("  re-saved %u identical %d\n", again,
                   again == needed && memcmp(out, twice, again) == 0);

            free(twice);
            cmsCloseProfile(back);
            free(out);
            cmsCloseProfile(h);
        }
    }

    /* -- the structural tag types ------------------------------------------- */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        cmsSetProfileVersion(h, 4.3);
        cmsSetColorSpace(h, cmsSigCmykData);

        cmsICCMeasurementConditions mc;
        memset(&mc, 0, sizeof mc);
        mc.Observer = 1;
        mc.Backing.X = 0.1; mc.Backing.Y = 0.2; mc.Backing.Z = 0.3;
        mc.Geometry = 2;
        mc.Flare = 0.125;
        mc.IlluminantType = cmsILLUMINANT_TYPE_D50;
        printf("measurement write %d\n", cmsWriteTag(h, cmsSigMeasurementTag, &mc));

        cmsICCViewingConditions vc;
        memset(&vc, 0, sizeof vc);
        vc.IlluminantXYZ.X = 0.9642; vc.IlluminantXYZ.Y = 1.0; vc.IlluminantXYZ.Z = 0.8249;
        vc.SurroundXYZ.X = 0.05; vc.SurroundXYZ.Y = 0.06; vc.SurroundXYZ.Z = 0.07;
        vc.IlluminantType = cmsILLUMINANT_TYPE_D65;
        printf("viewing write %d\n", cmsWriteTag(h, cmsSigViewingConditionsTag, &vc));

        cmsVideoSignalType cicp;
        memset(&cicp, 0, sizeof cicp);
        cicp.ColourPrimaries = 9;
        cicp.TransferCharacteristics = 16;
        cicp.MatrixCoefficients = 9;
        cicp.VideoFullRangeFlag = 1;
        printf("cicp write %d\n", cmsWriteTag(h, cmsSigcicpTag, &cicp));

        /* A colorant table, whose names are cut to 32 bytes on the way
         * out however long they were set. */
        cmsNAMEDCOLORLIST* colorants = cmsAllocNamedColorList(NULL, 4, 0, "", "");
        static const char* inks[4] = {
            "Cyan", "Magenta", "Yellow",
            "a colorant name that is far longer than thirty-two bytes"
        };
        for (int i = 0; i < 4; i++) {
            cmsUInt16Number pcs[3] = {
                (cmsUInt16Number) (i * 8000), (cmsUInt16Number) (i * 4000),
                (cmsUInt16Number) (i * 2000)
            };
            cmsAppendNamedColor(colorants, inks[i], pcs, NULL);
        }
        printf("colorants write %d\n", cmsWriteTag(h, cmsSigColorantTableTag, colorants));
        cmsFreeNamedColorList(colorants);

        cmsUInt32Number needed = 0;
        cmsSaveProfileToMem(h, NULL, &needed);
        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        cmsSaveProfileToMem(h, out, &room);
        feed_saved(out, needed);
        printf("structural saved %u\n", needed);

        cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
        cmsICCMeasurementConditions* rmc =
            (cmsICCMeasurementConditions*) cmsReadTag(back, cmsSigMeasurementTag);
        if (rmc)
            printf("  measurement obs %u geom %u flare %.6f illum %u backing %.6f\n",
                   rmc->Observer, rmc->Geometry, rmc->Flare, rmc->IlluminantType,
                   rmc->Backing.X);

        cmsICCViewingConditions* rvc =
            (cmsICCViewingConditions*) cmsReadTag(back, cmsSigViewingConditionsTag);
        if (rvc)
            printf("  viewing illum %.6f %.6f %.6f surround %.6f type %u\n",
                   rvc->IlluminantXYZ.X, rvc->IlluminantXYZ.Y, rvc->IlluminantXYZ.Z,
                   rvc->SurroundXYZ.X, rvc->IlluminantType);

        cmsVideoSignalType* rcicp =
            (cmsVideoSignalType*) cmsReadTag(back, cmsSigcicpTag);
        if (rcicp)
            printf("  cicp %u %u %u %u\n", rcicp->ColourPrimaries,
                   rcicp->TransferCharacteristics, rcicp->MatrixCoefficients,
                   rcicp->VideoFullRangeFlag);

        cmsNAMEDCOLORLIST* rlist =
            (cmsNAMEDCOLORLIST*) cmsReadTag(back, cmsSigColorantTableTag);
        if (rlist) {
            printf("  colorants %u\n", cmsNamedColorCount(rlist));
            for (cmsUInt32Number i = 0; i < cmsNamedColorCount(rlist); i++) {
                char name[64];
                cmsUInt16Number pcs[3];
                memset(name, 0, sizeof name);
                cmsNamedColorInfo(rlist, i, name, NULL, NULL, pcs, NULL);
                printf("    %u '%s' %u %u %u\n", i, name, pcs[0], pcs[1], pcs[2]);
            }
        }
        report("structural tags");

        cmsUInt32Number again = 0;
        cmsSaveProfileToMem(back, NULL, &again);
        unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
        cmsUInt32Number room2 = again;
        cmsSaveProfileToMem(back, twice, &room2);
        printf("structural re-saved %u identical %d\n", again,
               again == needed && memcmp(out, twice, again) == 0);

        free(twice);
        cmsCloseProfile(back);
        free(out);
        cmsCloseProfile(h);
    }

    /* -- the named-colour type ---------------------------------------------- */
    {
        cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
        cmsSetProfileVersion(h, 4.3);
        cmsSetColorSpace(h, cmsSigCmykData);
        cmsSetDeviceClass(h, cmsSigNamedColorClass);

        /* Prefix and suffix are list-wide; only the root varies per
         * entry, and all three are cut to 32 bytes. */
        cmsNAMEDCOLORLIST* list =
            cmsAllocNamedColorList(NULL, 5, 4, "PANTONE ", " CV");
        for (int i = 0; i < 5; i++) {
            char root[64];
            cmsUInt16Number pcs[3], ink[4];
            snprintf(root, sizeof root, "%d-%d", 100 + i, i);
            for (int k = 0; k < 3; k++) pcs[k] = (cmsUInt16Number) ((i + 1) * 6000 + k);
            for (int k = 0; k < 4; k++) ink[k] = (cmsUInt16Number) ((i + 1) * 3000 + k);
            cmsAppendNamedColor(list, root, pcs, ink);
        }
        printf("named write %d\n", cmsWriteTag(h, cmsSigNamedColor2Tag, list));
        cmsFreeNamedColorList(list);

        cmsUInt32Number needed = 0;
        cmsSaveProfileToMem(h, NULL, &needed);
        unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
        cmsUInt32Number room = needed;
        cmsSaveProfileToMem(h, out, &room);
        feed_saved(out, needed);
        printf("named saved %u\n", needed);

        cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
        cmsNAMEDCOLORLIST* got =
            (cmsNAMEDCOLORLIST*) cmsReadTag(back, cmsSigNamedColor2Tag);
        printf("named read %d count %u\n", got != NULL,
               got ? cmsNamedColorCount(got) : 0);
        if (got) {
            for (cmsUInt32Number i = 0; i < cmsNamedColorCount(got); i++) {
                char name[64], pre[64], suf[64];
                cmsUInt16Number pcs[3], ink[16];
                memset(name, 0, sizeof name);
                memset(pre, 0, sizeof pre);
                memset(suf, 0, sizeof suf);
                memset(ink, 0, sizeof ink);
                cmsNamedColorInfo(got, i, name, pre, suf, pcs, ink);
                printf("  %u '%s' pre '%s' suf '%s' pcs %u %u %u ink %u %u %u %u\n",
                       i, name, pre, suf, pcs[0], pcs[1], pcs[2],
                       ink[0], ink[1], ink[2], ink[3]);
            }
            /* The lookup matches the *root* only.  A caller that
             * assembles the name a user sees -- prefix, root, suffix --
             * and looks that up finds nothing. */
            printf("  index of root '102-2' = %d\n",
                   cmsNamedColorIndex(got, "102-2"));
            printf("  index of decorated 'PANTONE 102-2 CV' = %d\n",
                   cmsNamedColorIndex(got, "PANTONE 102-2 CV"));
            printf("  index of absent = %d\n", cmsNamedColorIndex(got, "nope"));
        }
        report("named colours");

        cmsUInt32Number again = 0;
        cmsSaveProfileToMem(back, NULL, &again);
        unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
        cmsUInt32Number room2 = again;
        cmsSaveProfileToMem(back, twice, &room2);
        printf("named re-saved %u identical %d\n", again,
               again == needed && memcmp(out, twice, again) == 0);

        free(twice);
        cmsCloseProfile(back);
        free(out);
        cmsCloseProfile(h);
    }

    /* -- the video card gamma type ------------------------------------------ */
    {
        /* vcgt is the one tag handed back as an array of three curves
         * rather than a single object, and it has two on-disk flavours:
         * three parametric formulas, or a sampled table. */
        for (int formula = 1; formula >= 0; formula--) {
            cmsHPROFILE h = cmsCreateProfilePlaceholder(NULL);
            cmsSetProfileVersion(h, 4.3);

            cmsToneCurve* v[3];
            if (formula) {
                /* Exactly parametric type 5, which is what sends it to
                 * the formula flavour. */
                for (int i = 0; i < 3; i++) {
                    cmsFloat64Number p[7] = { 2.2 + 0.1 * i, 0.0, 0.0, 0.0, 0.0, 0.02 * i, 0.0 };
                    p[1] = pow(1.0 - p[5], 1.0 / p[0]);
                    v[i] = cmsBuildParametricToneCurve(NULL, 5, p);
                }
            } else {
                cmsUInt16Number ramp[512];
                for (int j = 0; j < 512; j++) ramp[j] = (cmsUInt16Number) (j * 128);
                for (int i = 0; i < 3; i++)
                    v[i] = cmsBuildTabulatedToneCurve16(NULL, 512, ramp);
            }

            printf("vcgt %s write %d\n", formula ? "formula" : "table",
                   cmsWriteTag(h, cmsSigVcgtTag, v));
            for (int i = 0; i < 3; i++) cmsFreeToneCurve(v[i]);

            cmsUInt32Number needed = 0;
            cmsSaveProfileToMem(h, NULL, &needed);
            unsigned char* out = (unsigned char*) calloc(1, needed ? needed : 1);
            cmsUInt32Number room = needed;
            cmsSaveProfileToMem(h, out, &room);
            feed_saved(out, needed);
            printf("  saved %u\n", needed);

            cmsHPROFILE back = cmsOpenProfileFromMem(out, needed);
            cmsToneCurve** got = (cmsToneCurve**) cmsReadTag(back, cmsSigVcgtTag);
            printf("  read %d\n", got != NULL);
            if (got) {
                for (int i = 0; i < 3; i++) {
                    printf("    curve %d parametric %d entries %u\n", i,
                           cmsGetToneCurveParametricType(got[i]),
                           cmsGetToneCurveEstimatedTableEntries(got[i]));
                    for (int k = 0; k <= 8; k++)
                        feed_float(cmsEvalToneCurveFloat(got[i], (cmsFloat32Number) k / 8.0f));
                }
            }
            report(formula ? "vcgt formula" : "vcgt table");

            cmsUInt32Number again = 0;
            cmsSaveProfileToMem(back, NULL, &again);
            unsigned char* twice = (unsigned char*) calloc(1, again ? again : 1);
            cmsUInt32Number room2 = again;
            cmsSaveProfileToMem(back, twice, &room2);
            printf("  re-saved %u identical %d\n", again,
                   again == needed && memcmp(out, twice, again) == 0);

            free(twice);
            cmsCloseProfile(back);
            free(out);
            cmsCloseProfile(h);
        }
    }

    printf("profile probe OK\n");
    return 0;
}
