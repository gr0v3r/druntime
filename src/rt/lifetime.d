/**
 * This module contains all functions related to an object's lifetime:
 * allocation, resizing, deallocation, and finalization.
 *
 * Copyright: Copyright Digital Mars 2000 - 2010.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Walter Bright, Sean Kelly, Steven Schveighoffer
 */

/*          Copyright Digital Mars 2000 - 2010.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module rt.lifetime;

private
{
    import core.stdc.stdlib;
    import core.stdc.string;
    import core.stdc.stdarg;
    import core.bitop;
    import core.thread : thread_getTLSBlock;
    debug(PRINTF) import core.stdc.stdio;
}

private
{
    enum BlkAttr : uint
    {
        FINALIZE   = 0b0000_0001,
        NO_SCAN    = 0b0000_0010,
        NO_MOVE    = 0b0000_0100,
        APPENDABLE = 0b0000_1000,
        ALL_BITS   = 0b1111_1111
    }

    struct BlkInfo
    {
        void*  base;
        size_t size;
        uint   attr;
    }

    extern (C) uint gc_getAttr( in void* p );
    extern (C) uint gc_isCollecting( in void* p );
    extern (C) uint gc_setAttr( in void* p, uint a );
    extern (C) uint gc_clrAttr( in void* p, uint a );

    extern (C) void*  gc_malloc( size_t sz, uint ba = 0 );
    extern (C) BlkInfo  gc_qalloc( size_t sz, uint ba = 0 );
    extern (C) void*  gc_calloc( size_t sz, uint ba = 0 );
    extern (C) size_t gc_extend( void* p, size_t mx, size_t sz );
    extern (C) void   gc_free( void* p );

    extern (C) void*   gc_addrOf( in void* p );
    extern (C) size_t  gc_sizeOf( in void* p );
    extern (C) BlkInfo gc_query( in void* p );

    extern (C) void onFinalizeError( ClassInfo c, Throwable e );
    extern (C) void onOutOfMemoryError();

    extern (C) void _d_monitordelete(Object h, bool det = true);

    enum
    {
        PAGESIZE = 4096
    }

    alias bool function(Object) CollectHandler;
    __gshared CollectHandler collectHandler = null;

                enum : size_t
    {
        BIGLENGTHMASK = ~(cast(size_t)PAGESIZE - 1),
        SMALLPAD = 1,
        MEDPAD = ushort.sizeof,
        LARGEPREFIX = 16, // 16 bytes padding at the front of the array
        LARGEPAD = LARGEPREFIX + 1,
        MAXSMALLSIZE = 256-SMALLPAD,
        MAXMEDSIZE = (PAGESIZE / 2) - MEDPAD
    }
}


/**
 *
 */
extern (C) void* _d_allocmemory(size_t sz)
{
    return gc_malloc(sz);
}


/**
 *
 */
extern (C) Object _d_newclass(ClassInfo ci)
{
    void* p;

    debug(PRINTF) printf("_d_newclass(ci = %p, %s)\n", ci, cast(char *)ci.name);
    if (ci.m_flags & 1) // if COM object
    {   /* COM objects are not garbage collected, they are reference counted
         * using AddRef() and Release().  They get free'd by C's free()
         * function called by Release() when Release()'s reference count goes
         * to zero.
     */
        p = malloc(ci.init.length);
        if (!p)
            onOutOfMemoryError();
    }
    else
    {
        // TODO: should this be + 1 to avoid having pointers to the next block?
        p = gc_malloc(ci.init.length,
                      BlkAttr.FINALIZE | (ci.m_flags & 2 ? BlkAttr.NO_SCAN : 0));
        debug(PRINTF) printf(" p = %p\n", p);
    }

    debug(PRINTF)
    {
        printf("p = %p\n", p);
        printf("ci = %p, ci.init = %p, len = %d\n", ci, ci.init, ci.init.length);
        printf("vptr = %p\n", *cast(void**) ci.init);
        printf("vtbl[0] = %p\n", (*cast(void***) ci.init)[0]);
        printf("vtbl[1] = %p\n", (*cast(void***) ci.init)[1]);
        printf("init[0] = %x\n", (cast(uint*) ci.init)[0]);
        printf("init[1] = %x\n", (cast(uint*) ci.init)[1]);
        printf("init[2] = %x\n", (cast(uint*) ci.init)[2]);
        printf("init[3] = %x\n", (cast(uint*) ci.init)[3]);
        printf("init[4] = %x\n", (cast(uint*) ci.init)[4]);
    }

    // initialize it
    (cast(byte*) p)[0 .. ci.init.length] = ci.init[];

    debug(PRINTF) printf("initialization done\n");
    return cast(Object) p;
}


/**
 *
 */
extern (C) void _d_delinterface(void** p)
{
    if (*p)
    {
        Interface* pi = **cast(Interface ***)*p;
        Object     o  = cast(Object)(*p - pi.offset);

        _d_delclass(&o);
        *p = null;
    }
}


// used for deletion
private extern (D) alias void function (Object) fp_t;


/**
 *
 */
extern (C) void _d_delclass(Object* p)
{
    if (*p)
    {
        debug(PRINTF) printf("_d_delclass(%p)\n", *p);

        ClassInfo **pc = cast(ClassInfo **)*p;
        if (*pc)
        {
            ClassInfo c = **pc;

            rt_finalize(cast(void*) *p);

            if (c.deallocator)
            {
                fp_t fp = cast(fp_t)c.deallocator;
                (*fp)(*p); // call deallocator
                *p = null;
                return;
            }
        }
        else
        {
            rt_finalize(cast(void*) *p);
        }
        gc_free(cast(void*) *p);
        *p = null;
    }
}

/** dummy class used to lock for shared array appending */
private class ArrayAllocLengthLock
{}


/**
  Set the allocated length of the array block.  This is called
  any time an array is appended to or its length is set.

  The allocated block looks like this for blocks < PAGESIZE:

  |elem0|elem1|elem2|...|elemN-1|emptyspace|N*elemsize|


  The size of the allocated length at the end depends on the block size:

  a block of 16 to 256 bytes has an 8-bit length.

  a block with 512 to pagesize/2 bytes has a 16-bit length.

  For blocks >= pagesize, the length is a size_t and is at the beginning of the
  block.  The reason we have to do this is because the block can extend into
  more pages, so we cannot trust the block length if it sits at the end of the
  block, because it might have just been extended.  If we can prove in the
  future that the block is unshared, we may be able to change this, but I'm not
  sure it's important.

  In order to do put the length at the front, we have to provide 16 bytes
  buffer space in case the block has to be aligned properly.  In x86, certain
  SSE instructions will only work if the data is 16-byte aligned.  In addition,
  we need the sentinel byte to prevent accidental pointers to the next block.
  Because of the extra overhead, we only do this for page size and above, where
  the overhead is minimal compared to the block size.

  So for those blocks, it looks like:

  |N*elemsize|padding|elem0|elem1|...|elemN-1|emptyspace|sentinelbyte|

  where elem0 starts 16 bytes after the first byte.
  */
bool __setArrayAllocLength(ref BlkInfo info, size_t newlength, bool isshared, size_t oldlength = ~0)
{
    if(info.size <= 256)
    {
        if(newlength + SMALLPAD > info.size)
            // new size does not fit inside block
            return false;
        auto length = cast(ubyte *)(info.base + info.size - SMALLPAD);
        if(oldlength != ~0)
        {
            if(isshared)
            {
                synchronized(typeid(ArrayAllocLengthLock))
                {
                    if(*length == cast(ubyte)oldlength)
                        *length = cast(ubyte)newlength;
                    else
                        return false;
                }
            }
            else
            {
                if(*length == cast(ubyte)oldlength)
                    *length = cast(ubyte)newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no lock needed
            *length = cast(ubyte)newlength;
        }
    }
    else if(info.size < PAGESIZE)
    {
        if(newlength + MEDPAD > info.size)
            // new size does not fit inside block
            return false;
        auto length = cast(ushort *)(info.base + info.size - MEDPAD);
        if(oldlength != ~0)
        {
            if(isshared)
            {
                synchronized(typeid(ArrayAllocLengthLock))
                {
                    if(*length == oldlength)
                        *length = cast(ushort)newlength;
                    else
                        return false;
                }
            }
            else
            {
                if(*length == oldlength)
                    *length = cast(ushort)newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no lock needed
            *length = cast(ushort)newlength;
        }
    }
    else
    {
        if(newlength + LARGEPAD > info.size)
            // new size does not fit inside block
            return false;
        auto length = cast(size_t *)(info.base);
        if(oldlength != ~0)
        {
            if(isshared)
            {
                synchronized(typeid(ArrayAllocLengthLock))
                {
                    if(*length == oldlength)
                        *length = newlength;
                    else
                        return false;
                }
            }
            else
            {
                if(*length == oldlength)
                    *length = newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no lock needed
            *length = newlength;
        }
    }
    return true; // resize succeeded
}

/**
  get the start of the array for the given block
  */
void *__arrayStart(BlkInfo info)
{
    return info.base + ((info.size & BIGLENGTHMASK) ? LARGEPREFIX : 0);
}

/**
  get the padding required to allocate size bytes.  Note that the padding is
  NOT included in the passed in size.  Therefore, do NOT call this function
  with the size of an allocated block.
  */
size_t __arrayPad(size_t size)
{
    return size > MAXMEDSIZE ? LARGEPAD : (size > MAXSMALLSIZE ? MEDPAD : SMALLPAD);
}

/**
  cache for the lookup of the block info
  */
enum N_CACHE_BLOCKS=8;

// note this is TLS, so no need to sync.
BlkInfo *__blkcache_storage;

static if(N_CACHE_BLOCKS==1)
{
    version=single_cache;
}
else
{
    //version=simple_cache; // uncomment to test simple cache strategy
    //version=random_cache; // uncomment to test random cache strategy

    // ensure N_CACHE_BLOCKS is power of 2.
    static assert(!((N_CACHE_BLOCKS - 1) & N_CACHE_BLOCKS));

    version(random_cache)
    {
        int __nextRndNum = 0;
    }
    int __nextBlkIdx;
}

@property BlkInfo *__blkcache()
{
    if(!__blkcache_storage)
    {
        // allocate the block cache for the first time
        immutable size = BlkInfo.sizeof * N_CACHE_BLOCKS;
        __blkcache_storage = cast(BlkInfo *)malloc(size);
        memset(__blkcache_storage, 0, size);
    }
    return __blkcache_storage;
}

static __gshared size_t __blkcache_offset;
shared static this()
{
    void[] tls = thread_getTLSBlock();
    __blkcache_offset = (cast(void *)&__blkcache_storage) - tls.ptr;
}

// called when thread is exiting.
static ~this()
{
    // free the blkcache
    if(__blkcache_storage)
    {
        free(__blkcache_storage);
        __blkcache_storage = null;
    }
}


// we expect this to be called with the lock in place
extern(C) void rt_processGCMarks(void[] tls)
{
    // called after the mark routine to eliminate block cache data when it
    // might be ready to sweep

    debug(PRINTF) printf("processing GC Marks, %x\n", tls.ptr);
    auto cache = *cast(BlkInfo **)(tls.ptr + __blkcache_offset);
    if(cache)
    {
        debug(PRINTF) foreach(i; 0 .. N_CACHE_BLOCKS)
        {
            printf("cache entry %d has base ptr %x\tsize %d\tflags %x\n", i, cache[i].base, cache[i].size, cache[i].attr);
        }
        auto cache_end = cache + N_CACHE_BLOCKS;
        for(;cache < cache_end; ++cache)
        {
            if(cache.base != null && gc_isCollecting(cache.base))
            {
                debug(PRINTF) printf("clearing cache entry at %x\n", cache.base);
                cache.base = null; // clear that data.
            }
        }
    }
}

/**
  Get the cached block info of an interior pointer.  Returns null if the
  interior pointer's block is not cached.
  */
BlkInfo *__getBlkInfo(void *interior)
{
    BlkInfo *ptr = __blkcache;
    version(single_cache)
    {
        if(ptr.base && ptr.base <= interior && (interior - ptr.base) < ptr.size)
            return ptr;
        return null; // not in cache.
    }
    else version(simple_cache)
    {
        foreach(i; 0..N_CACHE_BLOCKS)
        {
            if(ptr.base && ptr.base <= interior && (interior - ptr.base) < ptr.size)
                return ptr;
            ptr++;
        }
    }
    else
    {
        // try to do a smart lookup, using __nextBlkIdx as the "head"
        auto curi = ptr + __nextBlkIdx;
        for(auto i = curi; i >= ptr; --i)
        {
            if(i.base && i.base <= interior && (interior - i.base) < i.size)
                return i;
        }

        for(auto i = ptr + N_CACHE_BLOCKS - 1; i > curi; --i)
        {
            if(i.base && i.base <= interior && (interior - i.base) < i.size)
                return i;
        }
    }
    return null; // not in cache.
}

void __insertBlkInfoCache(BlkInfo bi, BlkInfo *curpos)
{
    version(single_cache)
    {
        *__blkcache = bi;
    }
    else
    {
        version(simple_cache)
        {
            if(curpos)
                *curpos = bi;
            else
            {
                // note, this is a super-simple algorithm that does not care about
                // most recently used.  It simply uses a round-robin technique to
                // cache block info.  This means that the ordering of the cache
                // doesn't mean anything.  Certain patterns of allocation may
                // render the cache near-useless.
                __blkcache[__nextBlkIdx] = bi;
                __nextBlkIdx = (__nextBlkIdx+1) & (N_CACHE_BLOCKS - 1);
            }
        }
        else version(random_cache)
        {
            // strategy: if the block currently is in the cache, move the
            // current block index to the a random element and evict that
            // element.
            auto cache = __blkcache;
            if(!curpos)
            {
                __nextBlkIdx = (__nextRndNum = 1664525 * __nextRndNum + 1013904223) & (N_CACHE_BLOCKS - 1);
                curpos = cache + __nextBlkIdx;
            }
            else
            {
                __nextBlkIdx = curpos - cache;
            }
            *curpos = bi;
        }
        else
        {
            //
            // strategy: If the block currently is in the cache, swap it with
            // the head element.  Otherwise, move the head element up by one,
            // and insert it there.
            //
            auto cache = __blkcache;
            if(!curpos)
            {
                __nextBlkIdx = (__nextBlkIdx+1) & (N_CACHE_BLOCKS - 1);
                curpos = cache + __nextBlkIdx;
            }
            else if(curpos !is cache + __nextBlkIdx)
            {
                *curpos = cache[__nextBlkIdx];
                curpos = cache + __nextBlkIdx;
            }
            *curpos = bi;
        }
    }
}

/**
 * Shrink the "allocated" length of an array to be the exact size of the array.
 * It doesn't matter what the current allocated length of the array is, the
 * user is telling the runtime that he knows what he is doing.
 */
extern(C) void _d_arrayshrinkfit(TypeInfo ti, void[] arr)
{
    // note, we do not care about shared.  We are setting the length no matter
    // what, so no lock is required.
    debug(PRINTF) printf("_d_arrayshrinkfit, elemsize = %d, arr.ptr = x%x arr.length = %d\n", ti.next.tsize(), arr.ptr, arr.length);
    auto size = ti.next.tsize();                // array element size
    auto cursize = arr.length * size;
    auto   bic = __getBlkInfo(arr.ptr);
    auto   info = bic ? *bic : gc_query(arr.ptr);
    if(info.base && (info.attr & BlkAttr.APPENDABLE))
    {
        if(info.size >= PAGESIZE)
            // remove prefix from the current stored size
            cursize -= LARGEPREFIX;
        debug(PRINTF) printf("setting allocated size to %d\n", (arr.ptr - info.base) + cursize);
        __setArrayAllocLength(info, (arr.ptr - info.base) + cursize, false);
    }
}

/**
 * set the array capacity.  If the array capacity isn't currently large enough
 * to hold the requested capacity (in number of elements), then the array is
 * resized/reallocated to the appropriate size.  Pass in a requested capacity
 * of 0 to get the current capacity.  Returns the number of elements that can
 * actually be stored once the resizing is done.
 */
extern(C) size_t _d_arraysetcapacity(TypeInfo ti, size_t newcapacity, Array *p)
in
{
    assert(ti);
    assert(!p.length || p.data);
}
body
{
    // step 1, get the block
    auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
    auto bic = !isshared ? __getBlkInfo(p.data) : null;
    auto info = bic ? *bic : gc_query(p.data);
    auto size = ti.next.tsize();
    version (D_InlineAsm_X86)
    {
        size_t reqsize = void;

        asm
        {
            mov EAX, newcapacity;
            mul EAX, size;
            mov reqsize, EAX;
            jc  Loverflow;
        }
    }
    else
    {
        size_t reqsize = size * newcapacity;

        if (newcapacity > 0 && reqsize / newcapacity != size)
            goto Loverflow;
    }

    // step 2, get the actual "allocated" size.  If the allocated size does not
    // match what we expect, then we will need to reallocate anyways.

    // TODO: this probably isn't correct for shared arrays
    size_t curallocsize = void;
    size_t curcapacity = void;
    size_t offset = void;
    size_t arraypad = void;
    if(info.base !is null && (info.attr & BlkAttr.APPENDABLE))
    {
        if(info.size <= 256)
        {
            curallocsize = *(cast(ubyte *)(info.base + info.size - SMALLPAD));
            arraypad = SMALLPAD;
        }
        else if(info.size < PAGESIZE)
        {
            curallocsize = *(cast(ushort *)(info.base + info.size - MEDPAD));
            arraypad = MEDPAD;
        }
        else
        {
            curallocsize = *(cast(size_t *)(info.base));
            arraypad = LARGEPAD;
        }


        offset = p.data - __arrayStart(info);
        if(offset + p.length * size != curallocsize)
        {
            curcapacity = 0;
        }
        else
        {
            // figure out the current capacity of the block from the point
            // of view of the array.
            curcapacity = info.size - offset - arraypad;
        }
    }
    else
    {
        curallocsize = curcapacity = offset = 0;
    }
    debug(PRINTF) printf("_d_arraysetcapacity, p = x%d,%d, newcapacity=%d, info.size=%d, reqsize=%d, curallocsize=%d, curcapacity=%d, offset=%d\n", p.data, p.length, newcapacity, info.size, reqsize, curallocsize, curcapacity, offset);

    if(curcapacity >= reqsize)
    {
        // no problems, the current allocated size is large enough.
        return curcapacity / size;
    }

    // step 3, try to extend the array in place.
    if(info.size >= PAGESIZE && curcapacity != 0)
    {
        auto extendsize = reqsize + offset + LARGEPAD - info.size;
        auto u = gc_extend(p.data, extendsize, extendsize);
        if(u)
        {
            // extend worked, save the new current allocated size
            curcapacity = u - offset - LARGEPAD;
            return curcapacity / size;
        }
    }

    // step 4, if extending doesn't work, allocate a new array with at least the requested allocated size.
    auto datasize = p.length * size;
    reqsize += __arrayPad(reqsize);
    // copy attributes from original block, or from the typeinfo if the
    // original block doesn't exist.
    info = gc_qalloc(reqsize, (info.base ? info.attr : (!(ti.next.flags() & 1) ? BlkAttr.NO_SCAN : 0)) | BlkAttr.APPENDABLE);
    if(info.base is null)
        goto Loverflow;
    // copy the data over.
    // note that malloc will have initialized the data we did not request to 0.
    auto tgt = __arrayStart(info);
    memcpy(tgt, p.data, datasize);
    if(!(info.attr & BlkAttr.NO_SCAN))
    {
        // need to memset the newly requested data, except for the data that
        // malloc returned that we didn't request.
        void *endptr = info.base + reqsize;
        void *begptr = tgt + datasize;

        // sanity check
        assert(endptr >= begptr);
        memset(begptr, 0, endptr - begptr);
    }

    // set up the correct length
    __setArrayAllocLength(info, datasize, isshared);
    if(!isshared)
        __insertBlkInfoCache(info, bic);

    p.data = cast(byte *)tgt;

    // determine the padding.  This has to be done manually because __arrayPad
    // assumes you are not counting the pad size, and info.size does include
    // the pad.
    if(info.size <= 256)
        arraypad = SMALLPAD;
    else if(info.size < PAGESIZE)
        arraypad = MEDPAD;
    else
        arraypad = LARGEPAD;

    curcapacity = info.size - arraypad;
    return curcapacity / size;

Loverflow:
    onOutOfMemoryError();
    assert(0);
}

/**
 * Allocate a new array of length elements.
 * ti is the type of the resulting array, or pointer to element.
 * (For when the array is initialized to 0)
 */
extern (C) void[] _d_newarrayT(TypeInfo ti, size_t length)
{
    void[] result;
    auto size = ti.next.tsize();                // array element size

    debug(PRINTF) printf("_d_newarrayT(length = x%x, size = %d)\n", length, size);
    if (length == 0 || size == 0)
        result = null;
    else
    {
        version (D_InlineAsm_X86)
        {
            asm
            {
                mov     EAX,size        ;
                mul     EAX,length      ;
                mov     size,EAX        ;
                jc      Loverflow       ;
            }
        }
        else version(D_InlineAsm_X86_64)
        {
            asm
            {
                mov     RAX,size        ;
                mul     RAX,length      ;
                mov     size,RAX        ;
                jc      Loverflow       ;
            }
        }
        else
            size *= length;

        // increase the size by the array pad.
        auto info = gc_qalloc(size + __arrayPad(size), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
        debug(PRINTF) printf(" p = %p\n", info.base);
        // update the length of the array
        auto arrstart = __arrayStart(info);
        memset(arrstart, 0, size);
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        __setArrayAllocLength(info, size, isshared);
        result = arrstart[0..length];
    }
    return result;

Loverflow:
    onOutOfMemoryError();
    assert(0);
}

/**
 * For when the array has a non-zero initializer.
 */
extern (C) void[] _d_newarrayiT(TypeInfo ti, size_t length)
{
    void[] result;
    auto size = ti.next.tsize();                // array element size

    debug(PRINTF) printf("_d_newarrayiT(length = %d, size = %d)\n", length, size);

    if (length == 0 || size == 0)
        result = null;
    else
    {
        auto initializer = ti.next.init();
        auto isize = initializer.length;
        auto q = initializer.ptr;
        version (D_InlineAsm_X86)
        {
            asm
            {
                mov     EAX,size        ;
                mul     EAX,length      ;
                mov     size,EAX        ;
                jc      Loverflow       ;
            }
        }
        else version (D_InlineAsm_X86_64)
        {
            asm
            {
                mov     RAX,size        ;
                mul     RAX,length      ;
                mov     size,RAX        ;
                jc      Loverflow       ;
            }
        }
        else
            size *= length;

        auto info = gc_qalloc(size + __arrayPad(size), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
        debug(PRINTF) printf(" p = %p\n", info.base);
        auto arrstart = __arrayStart(info);
        if (isize == 1)
            memset(arrstart, *cast(ubyte*)q, size);
        else if (isize == int.sizeof)
        {
            int init = *cast(int*)q;
            size /= int.sizeof;
            for (size_t u = 0; u < size; u++)
            {
                (cast(int*)arrstart)[u] = init;
            }
        }
        else
        {
            for (size_t u = 0; u < size; u += isize)
            {
                memcpy(arrstart + u, q, isize);
            }
        }
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        __setArrayAllocLength(info, size, isshared);
        result = arrstart[0..length];
    }
    return result;

Loverflow:
    onOutOfMemoryError();
    assert(0);
}


/**
 *
 */
void[] _d_newarrayOpT(alias op)(TypeInfo ti, size_t ndims, va_list q)
{
    debug(PRINTF) printf("_d_newarrayOpT(ndims = %d)\n", ndims);
    if (ndims == 0)
        return null;
    else
    {
        void[] foo(TypeInfo ti, va_list ap, size_t ndims)
        {
            size_t dim;
            va_arg(ap, dim);

            debug(PRINTF) printf("foo(ti = %p, ti.next = %p, dim = %d, ndims = %d\n", ti, ti.next, dim, ndims);
            if (ndims == 1)
            {
                auto r = op(ti, dim);
                return *cast(void[]*)(&r);
            }
            else
            {
                auto allocsize = (void[]).sizeof * dim;
                auto info = gc_qalloc(allocsize + __arrayPad(allocsize));
                auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
                __setArrayAllocLength(info, allocsize, isshared);
                auto p = __arrayStart(info)[0 .. dim];

                version(X86)
                {
                    va_list ap2;
                    va_copy(ap2, ap);
                }
                for (size_t i = 0; i < dim; i++)
                {
                    version(X86_64)
                    {
                        __va_list argsave = *cast(__va_list*)ap;
                        va_list ap2 = &argsave;
                    }
                    (cast(void[]*)p.ptr)[i] = foo(ti.next, ap2, ndims - 1);
                }
                return p;
            }
        }

        version (none)
        {
            va_list q2;
            va_copy(q2, q);
            for (size_t i = 0; i < ndims; i++)
            {
                printf("index %d: %ul\n", i, va_arg!(size_t)(q2));
            }
            va_end(q2);
        }

        auto result = foo(ti, q, ndims);
        debug(PRINTF) printf("result = %llx\n", result);
        va_end(q);

        return result;
    }
}


/**
 *
 */
extern (C) void[] _d_newarraymT(TypeInfo ti, size_t ndims, ...)
{
    debug(PRINTF) printf("_d_newarraymT(ndims = %d)\n", ndims);

    if (ndims == 0)
        return null;
    else
    {
        va_list q;
        version(X86)
            va_start(q, ndims);
        else version(X86_64)
            va_start(q, __va_argsave);
        else
            static assert(false, "platform not supported");
        return _d_newarrayOpT!(_d_newarrayT)(ti, ndims, q);
    }
}


/**
 *
 */
extern (C) void[] _d_newarraymiT(TypeInfo ti, size_t ndims, ...)
{
    debug(PRINTF) printf("_d_newarraymiT(ndims = %d)\n", ndims);

    if (ndims == 0)
        return null;
    else
    {
        va_list q;
        version(X86)
            va_start(q, ndims);
        else version(X86_64)
            va_start(q, __va_argsave);
        else
            static assert(false, "platform not supported");
        return _d_newarrayOpT!(_d_newarrayiT)(ti, ndims, q);
    }
}


/**
 *
 */
struct Array
{
    size_t length;
    byte*  data;
}


/**
 * This function has been replaced by _d_delarray_t
 */
extern (C) void _d_delarray(Array *p)
{
    if (p)
    {
        assert(!p.length || p.data);

        if (p.data)
            gc_free(p.data);
        p.data = null;
        p.length = 0;
    }
}

debug(PRINTF)
{
    extern(C) void printArrayCache()
    {
        auto ptr = __blkcache;
        printf("CACHE: \n");
        foreach(i; 0 .. N_CACHE_BLOCKS)
        {
            printf("  %d\taddr:% .8x\tsize:% .10d\tflags:% .8x\n", i, ptr[i].base, ptr[i].size, ptr[i].attr);
        }
    }
}

/**
 *
 */
extern (C) void _d_delarray_t(Array *p, TypeInfo ti)
{
    if (p)
    {
        assert(!p.length || p.data);
        if (p.data)
        {
            if (ti)
            {
                // Call destructors on all the sub-objects
                auto sz = ti.tsize();
                auto pe = p.data;
                auto pend = pe + p.length * sz;
                while (pe != pend)
                {
                    pend -= sz;
                    ti.destroy(pend);
                }
            }

            // if p is in the cache, clear it as well
            if(auto bic = __getBlkInfo(p.data))
            {
                // clear the data from the cache, it's being deleted.
                bic.base = null;
            }
            gc_free(p.data);
        }
        p.data = null;
        p.length = 0;
    }
}


/**
 *
 */
extern (C) void _d_delmemory(void* *p)
{
    if (*p)
    {
        gc_free(*p);
        *p = null;
    }
}


/**
 *
 */
extern (C) void _d_callinterfacefinalizer(void *p)
{
    if (p)
    {
        Interface *pi = **cast(Interface ***)p;
        Object o = cast(Object)(p - pi.offset);
        rt_finalize(cast(void*)o);
    }
}


/**
 *
 */
extern (C) void _d_callfinalizer(void* p)
{
    rt_finalize( p );
}


/**
 *
 */
extern (C) void rt_setCollectHandler(CollectHandler h)
{
    collectHandler = h;
}


/**
 *
 */
extern (C) CollectHandler rt_getCollectHandler()
{
    return collectHandler;
}


/**
 *
 */
extern (C) void rt_finalize(void* p, bool det = true)
{
    debug(PRINTF) printf("rt_finalize(p = %p)\n", p);

    if (p) // not necessary if called from gc
    {
        ClassInfo** pc = cast(ClassInfo**)p;

        if (*pc)
        {
            ClassInfo c = **pc;
            byte[]    w = c.init;

            try
            {
                if (det || collectHandler is null || collectHandler(cast(Object)p))
                {
                    do
                    {
                        if (c.destructor)
                        {
                            fp_t fp = cast(fp_t)c.destructor;
                            (*fp)(cast(Object)p); // call destructor
                        }
                        c = c.base;
                    } while (c);
                }
                if ((cast(void**)p)[1]) // if monitor is not null
                    _d_monitordelete(cast(Object)p, det);
                (cast(byte*) p)[0 .. w.length] = w[];
            }
            catch (Throwable e)
            {
                onFinalizeError(**pc, e);
            }
            finally
            {
                *pc = null; // zero vptr
            }
        }
    }
}


/**
 * Resize dynamic arrays with 0 initializers.
 */
extern (C) byte[] _d_arraysetlengthT(TypeInfo ti, size_t newlength, Array *p)
in
{
    assert(ti);
    assert(!p.length || p.data);
}
body
{
    debug(PRINTF)
    {
        //printf("_d_arraysetlengthT(p = %p, sizeelem = %d, newlength = %d)\n", p, sizeelem, newlength);
        if (p)
            printf("\tp.data = %p, p.length = %d\n", p.data, p.length);
    }

    byte* newdata = void;
    if (newlength)
    {
        if (newlength <= p.length)
        {
            p.length = newlength;
            newdata = p.data;
            return newdata[0 .. newlength];
        }
        size_t sizeelem = ti.next.tsize();
        version (D_InlineAsm_X86)
        {
            size_t newsize = void;

            asm
            {
                mov EAX, newlength;
                mul EAX, sizeelem;
                mov newsize, EAX;
                jc  Loverflow;
            }
        }
        else version (D_InlineAsm_X86_64)
        {
            size_t newsize = void;

            asm
            {
                mov RAX, newlength;
                mul RAX, sizeelem;
                mov newsize, RAX;
                jc  Loverflow;
            }
        }
        else
        {
            size_t newsize = sizeelem * newlength;

            if (newsize / newlength != sizeelem)
                goto Loverflow;
        }

        debug(PRINTF) printf("newsize = %x, newlength = %x\n", newsize, newlength);

        auto   isshared = ti.classinfo is TypeInfo_Shared.classinfo;

        if (p.data)
        {
            newdata = p.data;
            if (newlength > p.length)
            {
                size_t size = p.length * sizeelem;
                auto   bic = !isshared ? __getBlkInfo(p.data) : null;
                auto   info = bic ? *bic : gc_query(p.data);
                if(info.base && (info.attr & BlkAttr.APPENDABLE))
                {
                    // calculate the extent of the array given the base.
                    size_t offset = p.data - __arrayStart(info);
                    if(info.size >= PAGESIZE)
                    {
                        // size of array is at the front of the block
                        if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                        {
                            // check to see if it failed because there is not
                            // enough space
                            if(*(cast(size_t*)info.base) == size + offset)
                            {
                                // not enough space, try extending
                                auto extendsize = newsize + offset + LARGEPAD - info.size;
                                auto u = gc_extend(p.data, extendsize, extendsize);
                                if(u)
                                {
                                    // extend worked, now try setting the length
                                    // again.
                                    info.size = u;
                                    if(__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                                    {
                                        if(!isshared)
                                            __insertBlkInfoCache(info, bic);
                                        goto L1;
                                    }
                                }
                            }

                            // couldn't do it, reallocate
                            info = gc_qalloc(newsize + LARGEPAD, info.attr);
                            __setArrayAllocLength(info, newsize, isshared);
                            if(!isshared)
                                __insertBlkInfoCache(info, bic);
                            newdata = cast(byte *)(info.base + LARGEPREFIX);
                            newdata[0 .. size] = p.data[0 .. size];
                        }
                        else if(!isshared && !bic)
                        {
                            // add this to the cache, it wasn't present previously.
                            __insertBlkInfoCache(info, null);
                        }
                    }
                    else if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                    {
                        // could not resize in place
                        info = gc_qalloc(newsize + __arrayPad(newsize), info.attr);
                        goto L2;
                    }
                    else if(!isshared && !bic)
                    {
                        // add this to the cache, it wasn't present previously.
                        __insertBlkInfoCache(info, null);
                    }
                }
                else
                {
                    info = gc_qalloc(newsize + __arrayPad(newsize), (info.base ? info.attr : !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN : 0) | BlkAttr.APPENDABLE);
                L2:
                    __setArrayAllocLength(info, newsize, isshared);
                    if(!isshared)
                        __insertBlkInfoCache(info, bic);
                    newdata = cast(byte *)__arrayStart(info);
                    newdata[0 .. size] = p.data[0 .. size];
                }
             L1:
                newdata[size .. newsize] = 0;
            }
        }
        else
        {
            // pointer was null, need to allocate
            auto info = gc_qalloc(newsize + __arrayPad(newsize), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
            __setArrayAllocLength(info, newsize, isshared);
            if(!isshared)
                __insertBlkInfoCache(info, null);
            newdata = cast(byte *)__arrayStart(info);
            newdata[0 .. newsize] = 0;
        }
    }
    else
    {
        newdata = p.data;
    }

    p.data = newdata;
    p.length = newlength;
    return newdata[0 .. newlength];

Loverflow:
    onOutOfMemoryError();
    assert(0);
}


/**
 * Resize arrays for non-zero initializers.
 *      p               pointer to array lvalue to be updated
 *      newlength       new .length property of array
 *      sizeelem        size of each element of array
 *      initsize        size of initializer
 *      ...             initializer
 */
extern (C) byte[] _d_arraysetlengthiT(TypeInfo ti, size_t newlength, Array *p)
in
{
    assert(!p.length || p.data);
}
body
{
    byte* newdata;
    size_t sizeelem = ti.next.tsize();
    void[] initializer = ti.next.init();
    size_t initsize = initializer.length;

    assert(sizeelem);
    assert(initsize);
    assert(initsize <= sizeelem);
    assert((sizeelem / initsize) * initsize == sizeelem);

    debug(PRINTF)
    {
        printf("_d_arraysetlengthiT(p = %p, sizeelem = %d, newlength = %d, initsize = %d)\n", p, sizeelem, newlength, initsize);
        if (p)
            printf("\tp.data = %p, p.length = %d\n", p.data, p.length);
    }

    if (newlength)
    {
        version (D_InlineAsm_X86)
        {
            size_t newsize = void;

            asm
            {
                mov     EAX,newlength   ;
                mul     EAX,sizeelem    ;
                mov     newsize,EAX     ;
                jc      Loverflow       ;
            }
        }
        else version (D_InlineAsm_X86_64)
        {
            size_t newsize = void;

            asm
            {
                mov     RAX,newlength   ;
                mul     RAX,sizeelem    ;
                mov     newsize,RAX     ;
                jc      Loverflow       ;
            }
        }
        else
        {
            size_t newsize = sizeelem * newlength;

            if (newsize / newlength != sizeelem)
                goto Loverflow;
        }
        debug(PRINTF) printf("newsize = %x, newlength = %x\n", newsize, newlength);


        size_t size = p.length * sizeelem;
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        if (p.data)
        {
            newdata = p.data;
            if (newlength > p.length)
            {
                auto   bic = !isshared ? __getBlkInfo(p.data) : null;
                auto   info = bic ? *bic : gc_query(p.data);

                // calculate the extent of the array given the base.
                size_t offset = p.data - __arrayStart(info);
                if(info.base && (info.attr & BlkAttr.APPENDABLE))
                {
                    if(info.size >= PAGESIZE)
                    {
                        // size of array is at the front of the block
                        if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                        {
                            // check to see if it failed because there is not
                            // enough space
                            if(*(cast(size_t*)info.base) == size + offset)
                            {
                                // not enough space, try extending
                                auto extendsize = newsize + offset + LARGEPAD - info.size;
                                auto u = gc_extend(p.data, extendsize, extendsize);
                                if(u)
                                {
                                    // extend worked, now try setting the length
                                    // again.
                                    info.size = u;
                                    if(__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                                    {
                                        if(!isshared)
                                            __insertBlkInfoCache(info, bic);
                                        goto L1;
                                    }
                                }
                            }

                            // couldn't do it, reallocate
                            info = gc_qalloc(newsize + LARGEPAD, info.attr);
                            __setArrayAllocLength(info, newsize, isshared);
                            if(!isshared)
                                __insertBlkInfoCache(info, bic);
                            newdata = cast(byte *)(info.base + LARGEPREFIX);
                            newdata[0 .. size] = p.data[0 .. size];
                        }
                        else if(!isshared && !bic)
                        {
                            // add this to the cache, it wasn't present previously.
                            __insertBlkInfoCache(info, null);
                        }
                    }
                    else if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                    {
                        // could not resize in place
                        info = gc_qalloc(newsize + __arrayPad(newsize), info.attr);
                        // goto sucks, but this is for optimization.
                        goto L2;
                    }
                    else if(!isshared && !bic)
                    {
                        // add this to the cache, it wasn't present previously.
                        __insertBlkInfoCache(info, null);
                    }
                }
                else
                {
                    // not appendable or not part of the heap yet.
                    info = gc_qalloc(newsize + __arrayPad(newsize), (info.base ? info.attr : !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN : 0) | BlkAttr.APPENDABLE);
                L2:
                    __setArrayAllocLength(info, newsize, isshared);
                    if(!isshared)
                        __insertBlkInfoCache(info, bic);
                    newdata = cast(byte *)__arrayStart(info);
                    newdata[0 .. size] = p.data[0 .. size];
                }
                L1: ;
            }
        }
        else
        {
            // length was zero, need to allocate
            auto info = gc_qalloc(newsize + __arrayPad(newsize), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
            __setArrayAllocLength(info, newsize, isshared);
            if(!isshared)
                __insertBlkInfoCache(info, null);
            newdata = cast(byte *)__arrayStart(info);
        }

        auto q = initializer.ptr; // pointer to initializer

        if (newsize > size)
        {
            if (initsize == 1)
            {
                debug(PRINTF) printf("newdata = %p, size = %d, newsize = %d, *q = %d\n", newdata, size, newsize, *cast(byte*)q);
                newdata[size .. newsize] = *(cast(byte*)q);
            }
            else
            {
                for (size_t u = size; u < newsize; u += initsize)
                {
                    memcpy(newdata + u, q, initsize);
                }
            }
        }
    }
    else
    {
        newdata = p.data;
    }

    p.data = newdata;
    p.length = newlength;
    return newdata[0 .. newlength];

Loverflow:
    onOutOfMemoryError();
    assert(0);
}


/**
 * Append y[] to array x[]
 */
extern (C) void[] _d_arrayappendT(TypeInfo ti, ref byte[] x, byte[] y)
{
    auto length = x.length;
    auto sizeelem = ti.next.tsize();            // array element size
    _d_arrayappendcTX(ti, x, y.length);
    memcpy(x.ptr + length * sizeelem, y.ptr, y.length * sizeelem);
    return x;
}


/**
 *
 */
size_t newCapacity(size_t newlength, size_t size)
{
    version(none)
    {
        size_t newcap = newlength * size;
    }
    else
    {
        /*
         * Better version by Dave Fladebo:
         * This uses an inverse logorithmic algorithm to pre-allocate a bit more
         * space for larger arrays.
         * - Arrays smaller than PAGESIZE bytes are left as-is, so for the most
         * common cases, memory allocation is 1 to 1. The small overhead added
         * doesn't affect small array perf. (it's virtually the same as
         * current).
         * - Larger arrays have some space pre-allocated.
         * - As the arrays grow, the relative pre-allocated space shrinks.
         * - The logorithmic algorithm allocates relatively more space for
         * mid-size arrays, making it very fast for medium arrays (for
         * mid-to-large arrays, this turns out to be quite a bit faster than the
         * equivalent realloc() code in C, on Linux at least. Small arrays are
         * just as fast as GCC).
         * - Perhaps most importantly, overall memory usage and stress on the GC
         * is decreased significantly for demanding environments.
         */
        size_t newcap = newlength * size;
        size_t newext = 0;

        if (newcap > PAGESIZE)
        {
            //double mult2 = 1.0 + (size / log10(pow(newcap * 2.0,2.0)));

            // redo above line using only integer math

            /*static int log2plus1(size_t c)
            {   int i;

                if (c == 0)
                    i = -1;
                else
                    for (i = 1; c >>= 1; i++)
                    {
                    }
                return i;
            }*/

            /* The following setting for mult sets how much bigger
             * the new size will be over what is actually needed.
             * 100 means the same size, more means proportionally more.
             * More means faster but more memory consumption.
             */
            //long mult = 100 + (1000L * size) / (6 * log2plus1(newcap));
            //long mult = 100 + (1000L * size) / log2plus1(newcap);
            long mult = 100 + (1000L) / (bsr(newcap) + 1);

            // testing shows 1.02 for large arrays is about the point of diminishing return
            //
            // Commented out because the multipler will never be < 102.  In order for it to be < 2,
            // then 1000L / (bsr(x) + 1) must be > 2.  The highest bsr(x) + 1
            // could be is 65 (64th bit set), and 1000L / 64 is much larger
            // than 2.  We need 500 bit integers for 101 to be achieved :)
            /*if (mult < 102)
                mult = 102;*/
            /*newext = cast(size_t)((newcap * mult) / 100);
            newext -= newext % size;*/
            // This version rounds up to the next element, and avoids using
            // mod.
            newext = cast(size_t)((newlength * mult + 99) / 100) * size;
            debug(PRINTF) printf("mult: %2.2f, alloc: %2.2f\n",mult/100.0,newext / cast(double)size);
        }
        newcap = newext > newcap ? newext : newcap;
        debug(PRINTF) printf("newcap = %d, newlength = %d, size = %d\n", newcap, newlength, size);
    }
    return newcap;
}


/**
 * Obsolete, replaced with _d_arrayappendcTX()
 */
extern (C) void[] _d_arrayappendcT(TypeInfo ti, ref byte[] x, ...)
{
    version(X86)
    {
        byte *argp = cast(byte*)(&ti + 2);
        return _d_arrayappendT(ti, x, argp[0..1]);
    }
    else version(X86_64)
    {
        // This code copies the element twice, which is annoying
        //   #1 is from va_arg copying from the varargs to b
        //   #2 is in _d_arrayappendT is copyinb b into the end of x
        // to fix this, we need a form of _d_arrayappendT that just grows
        // the array and leaves the copy to be done here by va_arg.
        byte[] b = (cast(byte*)alloca(ti.next.tsize))[0 .. ti.next.tsize];

        va_list ap;
        va_start(ap, __va_argsave);
        va_arg(ap, ti.next, cast(void*)b.ptr);
        va_end(ap);

        // The 0..1 here is strange.  Inside _d_arrayappendT, it ends up copying
        // b.length * ti.next.tsize bytes, which is right amount, but awfully
        // indirectly determined.  So, while it passes a darray of just one byte,
        // the entire block is copied correctly.  If the full b darray is passed
        // in, what's copied is ti.next.tsize * ti.next.tsize bytes, rather than
        // 1 * ti.next.tsize bytes.
        return _d_arrayappendT(ti, x, b[0..1]);
    }
    else
    {
        static assert(false, "platform not supported");
    }
}


/**************************************
 * Extend an array by n elements.
 * Caller must initialize those elements.
 */
extern (C)
byte[] _d_arrayappendcTX(TypeInfo ti, ref byte[] px, size_t n)
{
    // This is a cut&paste job from _d_arrayappendT(). Should be refactored.

    // only optimize array append where ti is not a shared type
    auto sizeelem = ti.next.tsize();            // array element size
    auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
    auto bic = !isshared ? __getBlkInfo(px.ptr) : null;
    auto info = bic ? *bic : gc_query(px.ptr);
    auto length = px.length;
    auto newlength = length + n;
    auto newsize = newlength * sizeelem;
    auto size = length * sizeelem;

    // calculate the extent of the array given the base.
    size_t offset = px.ptr - __arrayStart(info);
    if(info.attr & BlkAttr.APPENDABLE)
    {
        if(info.size >= PAGESIZE)
        {
            // size of array is at the front of the block
            if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
            {
                // check to see if it failed because there is not
                // enough space
                auto newcap = newCapacity(newlength, sizeelem);
                if(*(cast(size_t*)info.base) == size + offset)
                {
                    // not enough space, try extending
                    auto extendoffset = offset + LARGEPAD - info.size;
                    auto u = gc_extend(px.ptr, newsize + extendoffset, newcap + extendoffset);
                    if(u)
                    {
                        // extend worked, now try setting the length
                        // again.
                        info.size = u;
                        if(__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
                        {
                            if(!isshared)
                                __insertBlkInfoCache(info, bic);
                            goto L1;
                        }
                    }
                }

                // couldn't do it, reallocate
                info = gc_qalloc(newcap + LARGEPAD, info.attr);
                __setArrayAllocLength(info, newsize, isshared);
                if(!isshared)
                    __insertBlkInfoCache(info, bic);
                auto newdata = cast(byte *)info.base + LARGEPREFIX;
                memcpy(newdata, px.ptr, length * sizeelem);
                (cast(void **)(&px))[1] = newdata;
            }
            else if(!isshared && !bic)
            {
                __insertBlkInfoCache(info, null);
            }
        }
        else if(!__setArrayAllocLength(info, newsize + offset, isshared, size + offset))
        {
            // could not resize in place
            auto allocsize = newCapacity(newlength, sizeelem);
            info = gc_qalloc(allocsize + __arrayPad(allocsize), info.attr);
            goto L2;
        }
        else if(!isshared && !bic)
        {
            __insertBlkInfoCache(info, null);
        }
    }
    else
    {
        // not appendable or is null
        auto allocsize = newCapacity(newlength, sizeelem);
        info = gc_qalloc(allocsize + __arrayPad(allocsize), (info.base ? info.attr : !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN : 0) | BlkAttr.APPENDABLE);
    L2:
        __setArrayAllocLength(info, newsize, isshared);
        if(!isshared)
            __insertBlkInfoCache(info, bic);
        auto newdata = cast(byte *)__arrayStart(info);
        memcpy(newdata, px.ptr, length * sizeelem);
        (cast(void **)(&px))[1] = newdata;
    }

  L1:
    *cast(size_t *)&px = newlength;
    return px;
}


/**
 * Append dchar to char[]
 */
extern (C) void[] _d_arrayappendcd(ref byte[] x, dchar c)
{
    // c could encode into from 1 to 4 characters
    char[4] buf = void;
    byte[] appendthis; // passed to appendT
    if (c <= 0x7F)
    {
        buf.ptr[0] = cast(char)c;
        appendthis = (cast(byte *)buf.ptr)[0..1];
    }
    else if (c <= 0x7FF)
    {
        buf.ptr[0] = cast(char)(0xC0 | (c >> 6));
        buf.ptr[1] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..2];
    }
    else if (c <= 0xFFFF)
    {
        buf.ptr[0] = cast(char)(0xE0 | (c >> 12));
        buf.ptr[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf.ptr[2] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..3];
    }
    else if (c <= 0x10FFFF)
    {
        buf.ptr[0] = cast(char)(0xF0 | (c >> 18));
        buf.ptr[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf.ptr[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf.ptr[3] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..4];
    }
    else
        assert(0);      // invalid utf character - should we throw an exception instead?

    //
    // TODO: This always assumes the array type is shared, because we do not
    // get a typeinfo from the compiler.  Assuming shared is the safest option.
    // Once the compiler is fixed, the proper typeinfo should be forwarded.
    //
    return _d_arrayappendT(typeid(shared char[]), x, appendthis);
}


/**
 * Append dchar to wchar[]
 */
extern (C) void[] _d_arrayappendwd(ref byte[] x, dchar c)
{
    // c could encode into from 1 to 2 w characters
    wchar[2] buf = void;
    byte[] appendthis; // passed to appendT
    if (c <= 0xFFFF)
    {
        buf.ptr[0] = cast(wchar) c;
        // note that although we are passing only 1 byte here, appendT
        // interprets this as being an array of wchar, making the necessary
        // casts.
        appendthis = (cast(byte *)buf.ptr)[0..1];
    }
    else
    {
        buf.ptr[0] = cast(wchar) ((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
        buf.ptr[1] = cast(wchar) (((c - 0x10000) & 0x3FF) + 0xDC00);
        // ditto from above.
        appendthis = (cast(byte *)buf.ptr)[0..2];
    }

    //
    // TODO: This always assumes the array type is shared, because we do not
    // get a typeinfo from the compiler.  Assuming shared is the safest option.
    // Once the compiler is fixed, the proper typeinfo should be forwarded.
    //
    return _d_arrayappendT(typeid(shared wchar[]), x, appendthis);
}


/**
 *
 */
extern (C) byte[] _d_arraycatT(TypeInfo ti, byte[] x, byte[] y)
out (result)
{
    auto sizeelem = ti.next.tsize();            // array element size
    debug(PRINTF) printf("_d_arraycatT(%d,%p ~ %d,%p sizeelem = %d => %d,%p)\n", x.length, x.ptr, y.length, y.ptr, sizeelem, result.length, result.ptr);
    assert(result.length == x.length + y.length);
    for (size_t i = 0; i < x.length * sizeelem; i++)
        assert((cast(byte*)result)[i] == (cast(byte*)x)[i]);
    for (size_t i = 0; i < y.length * sizeelem; i++)
        assert((cast(byte*)result)[x.length * sizeelem + i] == (cast(byte*)y)[i]);

    size_t cap = gc_sizeOf(result.ptr);
    assert(!cap || cap > result.length * sizeelem);
}
body
{
    version (none)
    {
        /* Cannot use this optimization because:
         *  char[] a, b;
         *  char c = 'a';
         *  b = a ~ c;
         *  c = 'b';
         * will change the contents of b.
         */
        if (!y.length)
            return x;
        if (!x.length)
            return y;
    }

    auto sizeelem = ti.next.tsize();            // array element size
    debug(PRINTF) printf("_d_arraycatT(%d,%p ~ %d,%p sizeelem = %d)\n", x.length, x.ptr, y.length, y.ptr, sizeelem);
    size_t xlen = x.length * sizeelem;
    size_t ylen = y.length * sizeelem;
    size_t len  = xlen + ylen;

    if (!len)
        return null;

    auto info = gc_qalloc(len + __arrayPad(len), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
    byte* p = cast(byte*)__arrayStart(info);
    p[len] = 0; // guessing this is to optimize for null-terminated arrays?
    memcpy(p, x.ptr, xlen);
    memcpy(p + xlen, y.ptr, ylen);
    auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
    __setArrayAllocLength(info, len, isshared);
    return p[0 .. x.length + y.length];
}


/**
 *
 */
extern (C) byte[] _d_arraycatnT(TypeInfo ti, uint n, ...)
{
    size_t length;
    auto size = ti.next.tsize(); // array element size

    version(X86)
    {
        byte[]* p = cast(byte[]*)(&n + 1);

        for (auto i = 0; i < n; i++)
        {
            byte[] b = *p++;
            length += b.length;
        }
    }
    else
    {
        __va_list argsave = __va_argsave.va;
        va_list ap;
        va_start(ap, __va_argsave);
        for (auto i = 0; i < n; i++)
        {
            byte[] b;
            va_arg(ap, b);
            length += b.length;
        }
        va_end(ap);
    }
    if (!length)
        return null;

    auto allocsize = length * size;
    auto info = gc_qalloc(allocsize + __arrayPad(allocsize), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
    auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
    __setArrayAllocLength(info, allocsize, isshared);
    void *a = __arrayStart (info);

    version(X86)
    {
        p = cast(byte[]*)(&n + 1);

        size_t j = 0;
        for (auto i = 0; i < n; i++)
        {
            byte[] b = *p++;
            if (b.length)
            {
                memcpy(a + j, b.ptr, b.length * size);
                j += b.length * size;
            }
        }
    }
    else
    {
        va_list ap2 = &argsave;
        size_t j = 0;
        for (auto i = 0; i < n; i++)
        {
            byte[] b;
            va_arg(ap2, b);
            if (b.length)
            {
                memcpy(a + j, b.ptr, b.length * size);
                j += b.length * size;
            }
        }
        va_end(ap2);
    }

    Array2 result;
    result.length = length;
    result.ptr = a;
    return *cast(byte[]*)&result;
}


/**
 * Allocate the array, rely on the caller to do the initialization of the array.
 */
extern (C)
void* _d_arrayliteralTX(TypeInfo ti, size_t length)
{
    auto sizeelem = ti.next.tsize();            // array element size
    void* result;

    //printf("_d_arrayliteralTX(sizeelem = %d, length = %d)\n", sizeelem, length);
    if (length == 0 || sizeelem == 0)
        result = null;
    else
    {
        auto allocsize = length * sizeelem;
        auto info = gc_qalloc(allocsize + __arrayPad(allocsize), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        __setArrayAllocLength(info, allocsize, isshared);
        result = __arrayStart(info);
    }
    return result;
}

/**
 * The old way, obsolete.
 */
extern (C) void* _d_arrayliteralT(TypeInfo ti, size_t length, ...)
{
    auto sizeelem = ti.next.tsize();            // array element size
    void* result;

    debug(PRINTF) printf("_d_arrayliteralT(sizeelem = %d, length = %d)\n", sizeelem, length);
    if (length == 0 || sizeelem == 0)
        result = null;
    else
    {
        auto allocsize = length * sizeelem;
        auto info = gc_qalloc(allocsize + __arrayPad(allocsize), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        __setArrayAllocLength(info, allocsize, isshared);
        result = __arrayStart(info);

        version(X86)
        {
            va_list q;
            va_start(q, length);

            size_t stacksize = (sizeelem + int.sizeof - 1) & ~(int.sizeof - 1);

            if (stacksize == sizeelem)
            {
                memcpy(result, q, length * sizeelem);
            }
            else
            {
                for (size_t i = 0; i < length; i++)
                {
                    memcpy(result + i * sizeelem, q, sizeelem);
                    q += stacksize;
                }
            }

            va_end(q);
        }
        else
        {
            va_list q;
            va_start(q, __va_argsave);
            for (size_t i = 0; i < length; i++)
            {
                va_arg(q, ti.next, result + i * sizeelem);
            }
            va_end(q);
        }
    }
    return result;
}


/**
 * Support for array.dup property.
 */
struct Array2
{
    size_t length;
    void*  ptr;
}


/**
 *
 */
extern (C) void[] _adDupT(TypeInfo ti, Array2 a)
out (result)
{
    auto sizeelem = ti.next.tsize();            // array element size
    assert(memcmp((*cast(Array2*)&result).ptr, a.ptr, a.length * sizeelem) == 0);
}
body
{
    Array2 r;

    if (a.length)
    {
        auto sizeelem = ti.next.tsize();                // array element size
        auto size = a.length * sizeelem;
        auto info = gc_qalloc(size + __arrayPad(size), !(ti.next.flags() & 1) ? BlkAttr.NO_SCAN | BlkAttr.APPENDABLE : BlkAttr.APPENDABLE);
        auto isshared = ti.classinfo is TypeInfo_Shared.classinfo;
        __setArrayAllocLength(info, size, isshared);
        r.ptr = __arrayStart(info);
        r.length = a.length;
        memcpy(r.ptr, a.ptr, size);
    }
    return *cast(void[]*)(&r);
}


unittest
{
    int[] a;
    int[] b;
    int i;

    a = new int[3];
    a[0] = 1; a[1] = 2; a[2] = 3;
    b = a.dup;
    assert(b.length == 3);
    for (i = 0; i < 3; i++)
        assert(b[i] == i + 1);

    // test slice appending
    b = a[0..1];
    b ~= 4;
    for(i = 0; i < 3; i++)
        assert(a[i] == i + 1);

    // test reserving
    char[] arr = new char[4093];
    for(i = 0; i < arr.length; i++)
        arr[i] = cast(char)(i % 256);

    // note that these two commands used to cause corruption, which may not be
    // detected.
    arr.reserve(4094);
    auto arr2 = arr ~ "123";
    assert(arr2[0..arr.length] == arr);
    assert(arr2[arr.length..$] == "123");
}
