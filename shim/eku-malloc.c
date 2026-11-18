/* Bridge the glibc allocation ABI to the private mimalloc implementation.  */
#include <errno.h>
#include <malloc.h>
#include <malloc/malloc-internal.h>
#include <shlib-compat.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

extern void *mi_malloc (size_t) attribute_hidden;
extern void *mi_zalloc (size_t) attribute_hidden;
extern void *mi_realloc (void *, size_t) attribute_hidden;
extern void *mi_malloc_aligned (size_t, size_t) attribute_hidden;
extern void mi_free (void *) attribute_hidden;
extern size_t mi_usable_size (const void *) attribute_hidden;
extern void mi_collect (bool) attribute_hidden;
extern void mi_stats_print (void *) attribute_hidden;
extern void _mi_fork_child (void) attribute_hidden;

extern void *__libc_malloc (size_t);
extern void __libc_free (void *);
extern void *__libc_realloc (void *, size_t);
extern void *__libc_memalign (size_t, size_t);
extern struct mallinfo2 __libc_mallinfo2 (void);
extern int __libc_mallopt (int, int);

static size_t
malloc_size (size_t size)
{
  /* Keep the malloc ABI's alignment even for mimalloc's smallest bins.  */
  return size < _Alignof (max_align_t) ? _Alignof (max_align_t) : size;
}

static void *
allocation_failed (void)
{
  __set_errno (ENOMEM);
  return NULL;
}

static void *
allocation_result (void *p, int saved_errno)
{
  if (p == NULL)
    return allocation_failed ();
  __set_errno (saved_errno);
  return p;
}

libc_hidden_proto (__libc_malloc)
void *
__libc_malloc (size_t size)
{
  if (size > PTRDIFF_MAX)
    return allocation_failed ();
  int saved_errno = errno;
  return allocation_result (mi_malloc (malloc_size (size)), saved_errno);
}
libc_hidden_def (__libc_malloc)

libc_hidden_proto (__libc_free)
void
__libc_free (void *p)
{
  int saved_errno = errno;
  mi_free (p);
  __set_errno (saved_errno);
}
libc_hidden_def (__libc_free)

libc_hidden_proto (__libc_realloc)
void *
__libc_realloc (void *p, size_t size)
{
  /* Preserve glibc's historical realloc(p, 0) behavior.  */
  if (p != NULL && size == 0)
    {
      __libc_free (p);
      return NULL;
    }
  if (size > PTRDIFF_MAX)
    return allocation_failed ();
  int saved_errno = errno;
  return allocation_result (mi_realloc (p, malloc_size (size)), saved_errno);
}
libc_hidden_def (__libc_realloc)

void *
__libc_calloc (size_t count, size_t size)
{
  size_t total;
  if (__builtin_mul_overflow (count, size, &total) || total > PTRDIFF_MAX)
    return allocation_failed ();
  int saved_errno = errno;
  return allocation_result (mi_zalloc (malloc_size (total)), saved_errno);
}

static bool
is_power_of_two (size_t alignment)
{
  return alignment != 0 && (alignment & (alignment - 1)) == 0;
}

static void *
allocate_aligned (size_t alignment, size_t size)
{
  if (alignment <= _Alignof (max_align_t))
    return __libc_malloc (size);
  if (size > PTRDIFF_MAX)
    return allocation_failed ();
  int saved_errno = errno;
  return allocation_result (mi_malloc_aligned (malloc_size (size), alignment),
                            saved_errno);
}

libc_hidden_proto (__libc_memalign)
void *
__libc_memalign (size_t alignment, size_t size)
{
  if (alignment > SIZE_MAX / 2 + 1)
    {
      __set_errno (EINVAL);
      return NULL;
    }
  size_t rounded = _Alignof (max_align_t);
  while (rounded < alignment)
    rounded *= 2;
  return allocate_aligned (rounded, size);
}
libc_hidden_def (__libc_memalign)

void * weak_function
aligned_alloc (size_t alignment, size_t size)
{
  if (!is_power_of_two (alignment))
    {
      __set_errno (EINVAL);
      return NULL;
    }
  return allocate_aligned (alignment, size);
}

int
__posix_memalign (void **result, size_t alignment, size_t size)
{
  if (alignment < sizeof (void *) || !is_power_of_two (alignment))
    return EINVAL;
  int saved_errno = errno;
  void *p = allocate_aligned (alignment, size);
  __set_errno (saved_errno);
  if (p == NULL)
    return ENOMEM;
  *result = p;
  return 0;
}

void *
__libc_valloc (size_t size)
{
  return allocate_aligned (__getpagesize (), size);
}

void *
__libc_pvalloc (size_t size)
{
  size_t page = __getpagesize ();
  if (size > PTRDIFF_MAX - (page - 1))
    return allocation_failed ();
  size_t rounded = (size + page - 1) & ~(page - 1);
  return allocate_aligned (page, rounded == 0 ? page : rounded);
}

void weak_function
free_sized (void *p, size_t size)
{
  /* Use the interposable free, as glibc does.  */
  (void) size;
  free (p);
}

void weak_function
free_aligned_sized (void *p, size_t alignment, size_t size)
{
  (void) alignment;
  (void) size;
  free (p);
}

size_t
__malloc_usable_size (void *p)
{
  return mi_usable_size (p);
}

/* The ptmalloc diagnostics and tuning ABI cannot describe mimalloc heaps.  */
libc_hidden_proto (__libc_mallinfo2)
struct mallinfo2
__libc_mallinfo2 (void)
{
  return (struct mallinfo2) { 0 };
}
libc_hidden_def (__libc_mallinfo2)

struct mallinfo
__libc_mallinfo (void)
{
  return (struct mallinfo) { 0 };
}

libc_hidden_proto (__libc_mallopt)
int
__libc_mallopt (int parameter, int value)
{
  (void) parameter;
  (void) value;
  return 0;
}
libc_hidden_def (__libc_mallopt)

int
__malloc_info (int options, FILE *stream)
{
  (void) stream;
  __set_errno (options == 0 ? ENOSYS : EINVAL);
  return -1;
}

int
__malloc_trim (size_t pad)
{
  (void) pad;
  mi_collect (true);
  /* Mimalloc does not report whether collection returned memory.  */
  return 0;
}

void
__malloc_stats (void)
{
  mi_stats_print (NULL);
}

/* Mimalloc owns startup and thread teardown.  Register its fork handling
   here rather than in pthread_atfork, which itself can allocate memory.  */
void __ptmalloc_init (void) { }
void __malloc_arena_thread_freeres (void) { }
void __malloc_fork_lock_parent (void) { }
void __malloc_fork_unlock_parent (void) { }
void __malloc_fork_unlock_child (void) { _mi_fork_child (); }

strong_alias (__libc_malloc, malloc)
strong_alias (__libc_realloc, realloc)
strong_alias (__libc_free, free)
weak_alias (__libc_calloc, calloc)
weak_alias (__libc_memalign, memalign)
weak_alias (__posix_memalign, posix_memalign)
weak_alias (__libc_valloc, valloc)
weak_alias (__libc_pvalloc, pvalloc)
weak_alias (__malloc_usable_size, malloc_usable_size)
weak_alias (__malloc_info, malloc_info)
weak_alias (__libc_mallinfo, mallinfo)
weak_alias (__libc_mallinfo2, mallinfo2)
weak_alias (__libc_mallopt, mallopt)
weak_alias (__malloc_stats, malloc_stats)
weak_alias (__malloc_trim, malloc_trim)

#if SHLIB_COMPAT (libc, GLIBC_2_0, GLIBC_2_26)
compat_symbol (libc, __libc_free, cfree, GLIBC_2_0);
#endif

/* Retain legacy compatibility symbols without invoking hooks from mimalloc.  */
#include "hooks.c"
#include "morecore.c"
