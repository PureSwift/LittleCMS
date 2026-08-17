/* ioprobe.c - IO handlers and the field codecs, against the reference
 *
 * Two claims are being measured.  That the field codecs put the same bytes
 * in the same order into a stream, and take the same values back out —
 * this is the encoding every ICC profile is made of, so a difference here
 * is a difference in every file written.  And that a cmsIOHANDLER built by
 * the *caller* drives the library, because that struct's layout is public
 * and clients do build their own.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdio.h>
#include <string.h>

static void dump(const char* label, const unsigned char* bytes, unsigned length)
{
    printf("%-24s", label);
    for (unsigned i = 0; i < length; i++) printf(" %02x", bytes[i]);
    printf("\n");
}

/* -- a caller-built handler ------------------------------------------
 *
 * Backed by a fixed buffer, with the five entry points filled in by hand
 * exactly as a client would fill them.  If the library reaches around
 * these rather than through them, the counters below will say so.
 */

static unsigned char client_buffer[4096];
static unsigned client_position;
static unsigned client_reads;
static unsigned client_writes;
static unsigned client_tells;
static unsigned client_seeks;

static cmsUInt32Number ClientRead(cmsIOHANDLER* io, void* Buffer, cmsUInt32Number size, cmsUInt32Number count)
{
    (void) io;
    client_reads++;
    cmsUInt32Number length = size * count;
    if (client_position + length > sizeof client_buffer) return 0;
    memcpy(Buffer, client_buffer + client_position, length);
    client_position += length;
    return count;
}

static cmsBool ClientSeek(cmsIOHANDLER* io, cmsUInt32Number offset)
{
    (void) io;
    client_seeks++;
    if (offset > sizeof client_buffer) return FALSE;
    client_position = offset;
    return TRUE;
}

static cmsUInt32Number ClientTell(cmsIOHANDLER* io)
{
    (void) io;
    client_tells++;
    return client_position;
}

static cmsBool ClientWrite(cmsIOHANDLER* io, cmsUInt32Number size, const void* Buffer)
{
    client_writes++;
    if (client_position + size > sizeof client_buffer) return FALSE;
    memcpy(client_buffer + client_position, Buffer, size);
    client_position += size;
    if (client_position > io->UsedSpace) io->UsedSpace = client_position;
    return TRUE;
}

static cmsBool ClientClose(cmsIOHANDLER* io)
{
    (void) io;
    return TRUE;
}

static void client_reset(void)
{
    memset(client_buffer, 0, sizeof client_buffer);
    client_position = client_reads = client_writes = client_tells = client_seeks = 0;
}

static cmsIOHANDLER client_io;

static cmsIOHANDLER* client_handler(void)
{
    memset(&client_io, 0, sizeof client_io);
    client_io.ContextID = NULL;
    client_io.stream = NULL;
    client_io.UsedSpace = 0;
    client_io.ReportedSize = sizeof client_buffer;
    client_io.Read = ClientRead;
    client_io.Seek = ClientSeek;
    client_io.Close = ClientClose;
    client_io.Tell = ClientTell;
    client_io.Write = ClientWrite;
    return &client_io;
}

int main(void)
{
    /* -- what the codecs put on the wire ------------------------------ */

    client_reset();
    {
        cmsIOHANDLER* io = client_handler();
        cmsUInt16Number array[4] = { 0x0102, 0x0304, 0xFFFE, 0x0000 };
        cmsUInt64Number sixtyfour = (cmsUInt64Number) 0x0123456789ABCDEFULL;
        cmsCIEXYZ xyz = { 0.9642, 1.0, 0.8249 };

        printf("u8    %d\n", _cmsWriteUInt8Number(io, 0xA5));
        printf("u16   %d\n", _cmsWriteUInt16Number(io, 0x1234));
        printf("u32   %d\n", _cmsWriteUInt32Number(io, 0xDEADBEEF));
        printf("f32   %d\n", _cmsWriteFloat32Number(io, 0.5f));
        printf("u64   %d\n", _cmsWriteUInt64Number(io, &sixtyfour));
        printf("15.16 %d\n", _cmsWrite15Fixed16Number(io, 1.0));
        printf("xyz   %d\n", _cmsWriteXYZNumber(io, &xyz));
        printf("array %d\n", _cmsWriteUInt16Array(io, 4, array));
        printf("base  %d\n", _cmsWriteTypeBase(io, cmsSigXYZType));

        dump("bytes written", client_buffer, client_position);
        printf("position %u, writes %u\n", client_position, client_writes);
    }

    /* Read them all back and confirm the values survive the round trip. */
    {
        cmsIOHANDLER* io = &client_io;
        cmsUInt8Number u8; cmsUInt16Number u16; cmsUInt32Number u32;
        cmsFloat32Number f32; cmsUInt64Number u64; cmsFloat64Number fixed;
        cmsCIEXYZ xyz; cmsUInt16Number array[4];

        client_position = 0;
        printf("seek %d\n", io->Seek(io, 0));

        _cmsReadUInt8Number(io, &u8);
        _cmsReadUInt16Number(io, &u16);
        _cmsReadUInt32Number(io, &u32);
        _cmsReadFloat32Number(io, &f32);
        _cmsReadUInt64Number(io, &u64);
        _cmsRead15Fixed16Number(io, &fixed);
        _cmsReadXYZNumber(io, &xyz);
        _cmsReadUInt16Array(io, 4, array);
        cmsTagTypeSignature base = _cmsReadTypeBase(io);

        printf("u8 %02x u16 %04x u32 %08x\n", u8, u16, u32);
        printf("f32 %.9g fixed %.17g\n", (double) f32, fixed);
        printf("u64 %08x%08x\n",
               (unsigned) ((unsigned long long) u64 >> 32),
               (unsigned) ((unsigned long long) u64 & 0xFFFFFFFFu));
        printf("xyz %.17g %.17g %.17g\n", xyz.X, xyz.Y, xyz.Z);
        printf("array %04x %04x %04x %04x\n", array[0], array[1], array[2], array[3]);
        printf("base %08x\n", (unsigned) base);
    }

    /* A null destination consumes the field and discards it, which is how
     * the reference skips what it does not need. */
    {
        cmsIOHANDLER* io = &client_io;
        io->Seek(io, 0);
        printf("skip u8  %d\n", _cmsReadUInt8Number(io, NULL));
        printf("skip u16 %d\n", _cmsReadUInt16Number(io, NULL));
        printf("skip u32 %d\n", _cmsReadUInt32Number(io, NULL));
        printf("skip arr %d\n", _cmsReadUInt16Array(io, 2, NULL));
        printf("at %u\n", io->Tell(io));
    }

    /* Alignment is computed from the handler's own Tell, so the padding
     * depends on where the caller's stream actually is. */
    {
        cmsIOHANDLER* io = &client_io;
        for (unsigned at = 0; at < 9; at++) {
            io->Seek(io, at);
            cmsBool ok = _cmsWriteAlignment(io);
            printf("align write at %u -> %d, now %u\n", at, ok, io->Tell(io));
        }
        for (unsigned at = 0; at < 9; at++) {
            io->Seek(io, at);
            cmsBool ok = _cmsReadAlignment(io);
            printf("align read at %u -> %d, now %u\n", at, ok, io->Tell(io));
        }
    }

    /* The float reader refuses what the format should not contain: the
     * reference stores the value and still fails the read. */
    {
        cmsIOHANDLER* io = client_handler();
        client_position = 0;
        static const cmsUInt32Number patterns[] = {
            0x00000000,  /* +0        accepted */
            0x80000000,  /* -0        accepted */
            0x3F800000,  /* 1.0       accepted */
            0x7F800000,  /* +inf      refused  */
            0xFF800000,  /* -inf      refused  */
            0x7FC00000,  /* NaN       refused  */
            0x00000001,  /* subnormal refused  */
            0x7F7FFFFF,  /* FLT_MAX   refused, absurd magnitude */
            0x60AD78EC,  /* ~1e20     boundary */
        };
        for (size_t i = 0; i < sizeof patterns / sizeof *patterns; i++) {
            cmsFloat32Number value = 12345.0f;
            client_position = 0;
            _cmsWriteUInt32Number(io, patterns[i]);
            client_position = 0;
            cmsBool ok = _cmsReadFloat32Number(io, &value);
            printf("float %08x -> ok %d value %.9g\n",
                   (unsigned) patterns[i], ok, (double) value);
        }
    }

    /* -- the library's own handlers ------------------------------------ */

    /* NULL: counts bytes rather than storing them, which is how a profile
     * learns its own size before being written for real. */
    {
        cmsIOHANDLER* io = cmsOpenIOhandlerFromNULL(NULL);
        printf("null opened %d\n", io != NULL);
        _cmsWriteUInt32Number(io, 0x11223344);
        _cmsWriteUInt32Number(io, 0x55667788);
        printf("null tell %u used %u\n", io->Tell(io), io->UsedSpace);
        io->Seek(io, 4);
        printf("null after seek %u used %u\n", io->Tell(io), io->UsedSpace);
        printf("null close %d\n", cmsCloseIOhandler(io));
    }

    /* Memory, reading: the buffer is copied, so the caller may free it. */
    {
        unsigned char source[16];
        for (int i = 0; i < 16; i++) source[i] = (unsigned char) (i * 17);

        cmsIOHANDLER* io = cmsOpenIOhandlerFromMem(NULL, source, sizeof source, "r");
        printf("mem-r opened %d reported %u\n", io != NULL, io->ReportedSize);

        memset(source, 0, sizeof source);   /* the copy must be unaffected */

        cmsUInt32Number first;
        _cmsReadUInt32Number(io, &first);
        printf("mem-r first %08x tell %u\n", first, io->Tell(io));

        printf("mem-r seek past end %d\n", io->Seek(io, 99));
        printf("mem-r seek to end %d\n", io->Seek(io, 16));

        cmsUInt32Number overrun;
        printf("mem-r read past end %d\n", _cmsReadUInt32Number(io, &overrun));
        printf("mem-r close %d\n", cmsCloseIOhandler(io));
    }

    /* Memory, writing: straight into the caller's buffer. */
    {
        unsigned char destination[8];
        memset(destination, 0xEE, sizeof destination);

        cmsIOHANDLER* io = cmsOpenIOhandlerFromMem(NULL, destination, sizeof destination, "w");
        printf("mem-w opened %d reported %u\n", io != NULL, io->ReportedSize);
        printf("mem-w u32 %d\n", _cmsWriteUInt32Number(io, 0xCAFEBABE));
        printf("mem-w used %u\n", io->UsedSpace);
        printf("mem-w overflow %d\n", _cmsWriteXYZNumber(io, &(cmsCIEXYZ) { 1, 1, 1 }));
        dump("mem-w buffer", destination, sizeof destination);
        printf("mem-w close %d\n", cmsCloseIOhandler(io));
    }

    /* A mode the handler does not know is refused rather than guessed. */
    {
        unsigned char scratch[4];
        cmsIOHANDLER* io = cmsOpenIOhandlerFromMem(NULL, scratch, sizeof scratch, "x");
        printf("mem bad mode -> %s\n", io ? "opened" : "refused");
        io = cmsOpenIOhandlerFromMem(NULL, NULL, 4, "r");
        printf("mem NULL buffer -> %s\n", io ? "opened" : "refused");
    }

    /* Files: written, measured, read back. */
    {
        const char* path = "ioprobe.tmp";
        cmsIOHANDLER* io = cmsOpenIOhandlerFromFile(NULL, path, "w");
        printf("file-w opened %d\n", io != NULL);
        _cmsWriteUInt32Number(io, 0x01020304);
        _cmsWriteUInt32Number(io, 0x05060708);
        printf("file-w used %u\n", io->UsedSpace);
        printf("file-w close %d\n", cmsCloseIOhandler(io));

        io = cmsOpenIOhandlerFromFile(NULL, path, "r");
        printf("file-r opened %d reported %u\n", io != NULL, io->ReportedSize);
        printf("file-r physical '%s'\n", io->PhysicalFile);
        cmsUInt32Number value;
        _cmsReadUInt32Number(io, &value);
        printf("file-r first %08x tell %u\n", value, io->Tell(io));
        printf("file-r close %d\n", cmsCloseIOhandler(io));

        printf("file bad mode -> %s\n",
               cmsOpenIOhandlerFromFile(NULL, path, "rw") ? "opened" : "refused");
        printf("file missing -> %s\n",
               cmsOpenIOhandlerFromFile(NULL, "no-such-file.icc", "r") ? "opened" : "refused");

        FILE* stream = fopen(path, "rb");
        printf("filelength %ld\n", cmsfilelength(stream));
        printf("filelength leaves position %ld\n", ftell(stream));
        io = cmsOpenIOhandlerFromStream(NULL, stream);
        printf("stream opened %d reported %u\n", io != NULL, io->ReportedSize);
        printf("stream close %d\n", cmsCloseIOhandler(io));

        remove(path);
    }

    printf("io probe OK\n");
    return 0;
}
