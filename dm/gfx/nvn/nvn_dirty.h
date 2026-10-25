// Write-protect dirty-page tracking for guest memory (nvn_dirty.c)
#pragma once
#include <stddef.h>
#include <stdint.h>

void nvn_dirty_add_range(const void *mem, size_t size);           // Register a memory pool as a tracked range (the first call registers the page-fault hook and the host pre-write hook)
void nvn_dirty_stat(int *live, int *peak, int *cap);                // number of registered memory pools, peak, tracking table capacity (for the memory readout line)
void nvn_dirty_remove_range(const void *mem);                     // Pool destruction: restore protected pages to writable and mark invalid
int nvn_dirty_tracked(const void *addr, size_t len);
void nvn_dirty_protect(const void *addr, size_t len);              // Set the covered pages read-only
uint64_t nvn_dirty_now(void);                                      // Current generation: taken before upload, as the stamp of that content
int nvn_dirty_since(const void *addr, size_t len, uint64_t stamp); // Covered pages were written after the stamp -> 1
const void *nvn_dirty_span(const void *addr, size_t len);          // The tracked range holding the span (a handle to keep; NULL = untracked)
int nvn_dirty_since_span(const void *span, const void *addr, size_t len, uint64_t stamp);   // nvn_dirty_since through a kept handle (rechecked, scanned again only if it no longer holds the span)
void nvn_dirty_stats(uint64_t *faults, uint64_t *preps);           // Cumulative: number of page faults triggered by game writes, number of pages unprotected before host writes
void nvn_dirty_mp_stats(uint64_t *calls, uint64_t *pages, uint64_t *ns);   // Cumulative: this module's mprotect call count, pages covered, time spent
void nvn_dirty_slot_stats(int *live, int *used_slots, uint64_t *adds_total); // Currently live slots, slot table high-water mark, total number of registrations
void nvn_dirty_protect_all(void);                                  // diagnostic: protect every tracked range (DM_NVN_WPROBE)
void nvn_dirty_fault_log(int on); uint64_t nvn_dirty_fault_take(uintptr_t *out, uint64_t from, uint64_t max);   // diagnostic: addresses of the game's write faults (DM_NVN_WPROBE)
// Frame pipelining (DM_NVN_PIPELINE; nvn_dirty.c "Frame pipelining", nvn_mtl.m pipe_*): pages a binding reads directly are protected (cold) or shadowed by the caller (hot)
void nvn_pipe_init(uint64_t (*done)(void), int (*guest_pc)(void *uc));   // done: the newest completed fence; guest_pc: whether a fault's instruction is guest code
const void *nvn_pipe_span(const void *span, uint64_t lo, uint64_t hi);    // the tracked range holding [lo, hi) (span: a kept handle to check first), NULL = untracked
int nvn_pipe_hot(const void *span, uint64_t lo, uint64_t hi);             // 1: a page of [lo, hi) is hot (read a shadow), 0: none is, -1: untracked memory
void nvn_pipe_direct(const void *span, uint64_t lo, uint64_t hi, uint32_t fence);   // [lo, hi) is read directly by the submission with this fence: protected and stamped
uint32_t nvn_pipe_epoch(void);                                            // changes whenever a page turns hot or cold
void nvn_pipe_frame(void);                                                 // at each present: probes hot pages, turns unwritten ones cold
void nvn_pipe_stats(uint64_t s[12]);   // cumulative: faults on classified pages, of them stalls, stall ns, timeouts, host writes, pages turned hot, probes, demoted, pages protected, hot pages protected again; hot list size
