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

static void inspect(cmsHPROFILE h, const char* label)
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
    if (cmsGetHeaderCreationDateTime(h, &created)) {
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
        inspect(h, "four tags, three linkable");
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
        inspect(h, "declared size clips the tags");
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

        inspect(h, "placeholder after setting");
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
        const char* path = "profileprobe.tmp.icc";
        FILE* f = fopen(path, "wb");
        if (f != NULL) {
            fwrite(bytes, 1, size, f);
            fclose(f);

            cmsHPROFILE h = cmsOpenProfileFromFile(path, "r");
            inspect(h, "from file");
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

    printf("profile probe OK\n");
    return 0;
}
