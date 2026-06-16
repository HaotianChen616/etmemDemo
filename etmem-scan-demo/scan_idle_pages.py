#!/usr/bin/env python3
import argparse
import csv
import errno
import os
import signal
import sys
import time
from dataclasses import dataclass, field


PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
PAGE_SHIFT = PAGE_SIZE.bit_length() - 1
PMD_SIZE = 1 << (((PAGE_SHIFT - 3) * (4 - 2)) + 3)
PUD_SIZE = 1 << (((PAGE_SHIFT - 3) * (4 - 1)) + 3)
MIN_IDLE_READ_BYTES = 19
DEFAULT_READ_BYTES = 8192
READ_WEIGHT = 1
WRITE_WEIGHT = 3

PTE_ACCESSED = 0
PMD_ACCESSED = 1
PUD_PRESENT = 2
PTE_DIRTY = 3
PMD_DIRTY = 4
PTE_IDLE = 5
PMD_IDLE = 6
PMD_IDLE_PTES = 7
PTE_HOLE = 8
PMD_HOLE = 9
PIP_CMD = 10
PIP_CMD_SET_HVA = 0xA0

TYPE_SIZE = {
    PTE_ACCESSED: PAGE_SIZE,
    PMD_ACCESSED: PMD_SIZE,
    PUD_PRESENT: PUD_SIZE,
    PTE_DIRTY: PAGE_SIZE,
    PMD_DIRTY: PMD_SIZE,
    PTE_IDLE: PAGE_SIZE,
    PMD_IDLE: PMD_SIZE,
    PMD_IDLE_PTES: PMD_SIZE,
    PTE_HOLE: PAGE_SIZE,
    PMD_HOLE: PMD_SIZE,
}

TYPE_NAME = {
    PTE_ACCESSED: "pte_accessed",
    PMD_ACCESSED: "pmd_accessed",
    PUD_PRESENT: "pud_present",
    PTE_DIRTY: "pte_dirty",
    PMD_DIRTY: "pmd_dirty",
    PTE_IDLE: "pte_idle",
    PMD_IDLE: "pmd_idle",
    PMD_IDLE_PTES: "pmd_idle_ptes",
    PTE_HOLE: "pte_hole",
    PMD_HOLE: "pmd_hole",
}

READ_TYPES = {PTE_ACCESSED, PMD_ACCESSED, PUD_PRESENT}
WRITE_TYPES = {PTE_DIRTY, PMD_DIRTY}
HOT_TYPES = READ_TYPES | WRITE_TYPES
COLD_TYPES = {PTE_IDLE, PMD_IDLE, PMD_IDLE_PTES}
HOLE_TYPES = {PTE_HOLE, PMD_HOLE}


@dataclass
class VMA:
    start: int
    end: int
    perms: str
    offset: str
    dev: str
    inode: str
    path: str

    @property
    def size(self):
        return self.end - self.start

    @property
    def label(self):
        if self.path:
            return self.path
        return "[anonymous]"


@dataclass
class Stats:
    hot: int = 0
    cold: int = 0
    hole: int = 0
    other: int = 0
    by_type: dict = field(default_factory=dict)

    def add(self, page_type, byte_count):
        if byte_count <= 0:
            return
        self.by_type[page_type] = self.by_type.get(page_type, 0) + byte_count
        if page_type in HOT_TYPES:
            self.hot += byte_count
        elif page_type in COLD_TYPES:
            self.cold += byte_count
        elif page_type in HOLE_TYPES:
            self.hole += byte_count
        else:
            self.other += byte_count

    def merge(self, other):
        self.hot += other.hot
        self.cold += other.cold
        self.hole += other.hole
        self.other += other.other
        for page_type, byte_count in other.by_type.items():
            self.by_type[page_type] = self.by_type.get(page_type, 0) + byte_count

    @property
    def present(self):
        return self.hot + self.cold + self.other

    @property
    def total_reported(self):
        return self.present + self.hole


def parse_args():
    parser = argparse.ArgumentParser(
        description="Observe etmem_scan idle_pages and report slide-style hot/cold memory distribution."
    )
    parser.add_argument("--pid", type=int, required=True, help="target process PID")
    parser.add_argument(
        "--interval",
        type=float,
        default=10.0,
        help="seconds before the next reported scan job, matching etmem project interval",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.0,
        help="seconds after each inner scan round, matching etmem project sleep",
    )
    parser.add_argument("--loop", type=int, default=1, help="inner scan rounds per reported sample")
    parser.add_argument("--t", type=int, default=1, help="cold threshold: weighted access_count < T is cold")
    parser.add_argument(
        "--samples",
        type=int,
        default=3,
        help="number of reported samples; use 0 to run forever",
    )
    parser.add_argument("--watch", action="store_true", help="run forever until interrupted")
    parser.add_argument("--warmup", action="store_true", help="discard one scan before sampling")
    parser.add_argument("--top", type=int, default=10, help="number of coldest VMAs to print")
    parser.add_argument(
        "--vma-filter",
        choices=("slide-anon", "anon", "rw-private", "all"),
        default="slide-anon",
        help="which VMAs to scan; slide-anon follows slide's source-level anonymous VMA rule",
    )
    parser.add_argument("--min-vma-kb", type=int, default=1024, help="skip smaller VMAs")
    parser.add_argument("--csv", help="write summary samples to this CSV file")
    parser.add_argument("--vma-csv", help="write per-VMA rows to this CSV file")
    parser.add_argument(
        "--page-csv",
        help="write one row per base page with final hot/cold classification and access count",
    )
    parser.add_argument(
        "--page-rounds",
        action="store_true",
        help="include per-loop-round page states in --page-csv; can make very large files",
    )
    parser.add_argument(
        "--page-include-holes",
        action="store_true",
        help="also include hole/non-present pages in --page-csv",
    )
    parser.add_argument("--read-bytes", type=int, default=DEFAULT_READ_BYTES)
    return parser.parse_args()


def bytes_to_mb(byte_count):
    return byte_count / 1024 / 1024


def read_status_kb(pid, key):
    try:
        with open(f"/proc/{pid}/status", "r", encoding="ascii") as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except FileNotFoundError:
        return 0
    return 0


def read_major_faults(pid):
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="ascii") as f:
            data = f.read()
    except FileNotFoundError:
        return 0
    rest = data.rsplit(") ", 1)[1]
    fields = rest.split()
    return int(fields[9])


def parse_maps(pid, vma_filter, min_vma_bytes):
    vmas = []
    with open(f"/proc/{pid}/maps", "r", encoding="ascii") as f:
        for line in f:
            parts = line.rstrip("\n").split(maxsplit=5)
            if len(parts) < 5:
                continue
            address, perms, offset, dev, inode = parts[:5]
            path = parts[5] if len(parts) == 6 else ""
            start_s, end_s = address.split("-", 1)
            vma = VMA(int(start_s, 16), int(end_s, 16), perms, offset, dev, inode, path)
            if vma.size < min_vma_bytes:
                continue
            if vma_filter == "slide-anon":
                if is_slide_anonymous_vma(vma):
                    vmas.append(vma)
                continue
            if "r" not in perms:
                continue
            if path in ("[vvar]", "[vdso]", "[vsyscall]"):
                continue
            if vma_filter == "anon" and not is_anonymous_vma(vma):
                continue
            if vma_filter == "rw-private" and not (perms.startswith("rw") and "p" in perms):
                continue
            vmas.append(vma)
    return vmas


def read_smaps_rss_kb(pid):
    rss_by_range = {}
    current = None
    with open(f"/proc/{pid}/smaps", "r", encoding="ascii") as f:
        for line in f:
            parts = line.rstrip("\n").split(maxsplit=5)
            if parts and "-" in parts[0]:
                try:
                    start_s, end_s = parts[0].split("-", 1)
                    current = (int(start_s, 16), int(end_s, 16))
                except ValueError:
                    current = None
                continue
            if current and line.startswith("Rss:"):
                rss_by_range[current] = int(line.split()[1])
    return rss_by_range


def is_anonymous_vma(vma):
    if vma.inode == "0" and not vma.path:
        return True
    if vma.path in ("[heap]", "[stack]"):
        return True
    if vma.path.startswith("[anon"):
        return True
    return False


def is_slide_anonymous_vma(vma):
    may_share = len(vma.perms) > 3 and vma.perms[3] != "p"
    executable = len(vma.perms) > 2 and vma.perms[2] == "x"
    writable = len(vma.perms) > 1 and vma.perms[1] == "w"
    try:
        inode = int(vma.inode)
    except ValueError:
        inode = -1
    return not may_share and not executable and (inode == 0 or writable)


def open_idle_pages(pid, _args):
    return os.open(f"/proc/{pid}/idle_pages", os.O_RDONLY)


def scan_byte_count_for_range(start, end, desired_read_bytes):
    virtual_bytes_per_output_byte = PAGE_SIZE * 8
    needed = (end - start + virtual_bytes_per_output_byte - 1) // virtual_bytes_per_output_byte
    return max(MIN_IDLE_READ_BYTES, min(desired_read_bytes, needed))


def parse_idle_stream(data, initial_addr, clip_start, clip_end):
    stats = Stats()
    cursor = initial_addr
    i = 0
    while i < len(data):
        byte = data[i]
        page_type = byte >> 4
        page_count = byte & 0x0F
        if page_type == PIP_CMD:
            if byte == PIP_CMD_SET_HVA and i + 8 < len(data):
                cursor = int.from_bytes(data[i + 1 : i + 9], byteorder="big")
                i += 9
                continue
            i += 1
            continue

        page_size = TYPE_SIZE.get(page_type)
        if page_size is None:
            i += 1
            continue

        run_start = cursor
        run_end = cursor + page_count * page_size
        clipped_start = max(run_start, clip_start)
        clipped_end = min(run_end, clip_end)
        if clipped_end > clipped_start:
            stats.add(page_type, clipped_end - clipped_start)
        cursor = run_end
        i += 1
    return stats


def parse_idle_stream_intervals(data, initial_addr, clip_start, clip_end):
    intervals = []
    cursor = initial_addr
    i = 0
    while i < len(data):
        byte = data[i]
        page_type = byte >> 4
        page_count = byte & 0x0F
        if page_type == PIP_CMD:
            if byte == PIP_CMD_SET_HVA and i + 8 < len(data):
                cursor = int.from_bytes(data[i + 1 : i + 9], byteorder="big")
                i += 9
                continue
            i += 1
            continue

        page_size = TYPE_SIZE.get(page_type)
        if page_size is None:
            i += 1
            continue

        run_start = cursor
        run_end = cursor + page_count * page_size
        clipped_start = max(run_start, clip_start)
        clipped_end = min(run_end, clip_end)
        if clipped_end > clipped_start:
            intervals.append((clipped_start, clipped_end, page_type))
        cursor = run_end
        i += 1
    return intervals


def scan_vma(fd, vma, read_bytes):
    stats = Stats()
    pos = vma.start
    while pos < vma.end:
        read_count = scan_byte_count_for_range(pos, vma.end, read_bytes)
        os.lseek(fd, pos, os.SEEK_SET)
        try:
            data = os.read(fd, read_count)
        except OSError as exc:
            if exc.errno in (errno.EINVAL, errno.EFAULT):
                break
            raise
        if not data:
            break
        stats.merge(parse_idle_stream(data, pos, vma.start, vma.end))
        new_pos = os.lseek(fd, 0, os.SEEK_CUR)
        if new_pos <= pos:
            break
        pos = new_pos
    return stats


def scan_vma_intervals(fd, vma, read_bytes):
    intervals = []
    pos = vma.start
    while pos < vma.end:
        read_count = scan_byte_count_for_range(pos, vma.end, read_bytes)
        os.lseek(fd, pos, os.SEEK_SET)
        try:
            data = os.read(fd, read_count)
        except OSError as exc:
            if exc.errno in (errno.EINVAL, errno.EFAULT):
                break
            raise
        if not data:
            break
        intervals.extend(parse_idle_stream_intervals(data, pos, vma.start, vma.end))
        new_pos = os.lseek(fd, 0, os.SEEK_CUR)
        if new_pos <= pos:
            break
        pos = new_pos
    return intervals


def scan_process(pid, args):
    vmas = parse_maps(pid, args.vma_filter, args.min_vma_kb * 1024)
    rss_by_range = read_smaps_rss_kb(pid)
    fd = open_idle_pages(pid, args)
    total = Stats()
    rows = []
    scanned_vma_rss_kb = 0
    try:
        for vma in vmas:
            vma_rss_kb = rss_by_range.get((vma.start, vma.end), 0)
            scanned_vma_rss_kb += vma_rss_kb
            stats = scan_vma(fd, vma, args.read_bytes)
            total.merge(stats)
            if stats.total_reported > 0 or vma_rss_kb > 0:
                rows.append((vma, stats, vma_rss_kb))
    finally:
        os.close(fd)
    return total, rows, scanned_vma_rss_kb


def page_indices(start, end):
    first = start // PAGE_SIZE
    last = (end + PAGE_SIZE - 1) // PAGE_SIZE
    return range(first, last)


@dataclass
class VMAWindow:
    access_counts: dict = field(default_factory=dict)
    classifiable_pages: set = field(default_factory=set)
    other_pages: set = field(default_factory=set)
    last_hole_pages: set = field(default_factory=set)
    round_states: dict = field(default_factory=dict)

    def update(self, intervals, round_idx=None, track_rounds=False):
        current_holes = set()
        for start, end, page_type in intervals:
            pages = page_indices(start, end)
            if page_type in READ_TYPES or page_type in WRITE_TYPES:
                weight = WRITE_WEIGHT if page_type in WRITE_TYPES else READ_WEIGHT
                for page in pages:
                    self.classifiable_pages.add(page)
                    self.access_counts[page] = self.access_counts.get(page, 0) + weight
                    self.record_round_state(page, page_type, round_idx, track_rounds)
            elif page_type in COLD_TYPES:
                for page in pages:
                    self.classifiable_pages.add(page)
                    self.record_round_state(page, page_type, round_idx, track_rounds)
            elif page_type in HOLE_TYPES:
                for page in pages:
                    current_holes.add(page)
                    self.record_round_state(page, page_type, round_idx, track_rounds)
            else:
                for page in pages:
                    self.other_pages.add(page)
                    self.record_round_state(page, page_type, round_idx, track_rounds)
        self.last_hole_pages = current_holes

    def record_round_state(self, page, page_type, round_idx, track_rounds):
        if not track_rounds or round_idx is None:
            return
        self.round_states.setdefault(page, {})[round_idx] = TYPE_NAME.get(page_type, f"type_{page_type}")

    def stats(self, threshold):
        stats = Stats()
        for page in self.classifiable_pages:
            if self.access_counts.get(page, 0) >= threshold:
                stats.hot += PAGE_SIZE
            else:
                stats.cold += PAGE_SIZE
        stats.other = len(self.other_pages - self.classifiable_pages) * PAGE_SIZE
        stats.hole = len(self.last_hole_pages) * PAGE_SIZE
        return stats

    def page_class(self, page, threshold):
        if page in self.classifiable_pages:
            if self.access_counts.get(page, 0) >= threshold:
                return "hot"
            return "cold"
        if page in self.other_pages:
            return "other"
        if page in self.last_hole_pages:
            return "hole"
        return "unknown"

    def iter_pages(self, include_holes):
        pages = set(self.classifiable_pages)
        pages.update(self.other_pages - self.classifiable_pages)
        if include_holes:
            pages.update(self.last_hole_pages)
        return sorted(pages)


def scan_process_window(pid, args, page_writer=None, sample_no=None):
    vmas = parse_maps(pid, args.vma_filter, args.min_vma_kb * 1024)
    rss_by_range = read_smaps_rss_kb(pid)
    windows = {idx: VMAWindow() for idx in range(len(vmas))}
    track_rounds = page_writer is not None and args.page_rounds

    for scan_idx in range(args.loop):
        fd = open_idle_pages(pid, args)
        try:
            for idx, vma in enumerate(vmas):
                intervals = scan_vma_intervals(fd, vma, args.read_bytes)
                windows[idx].update(intervals, scan_idx, track_rounds)
        finally:
            os.close(fd)
        if args.sleep > 0:
            time.sleep(args.sleep)

    total = Stats()
    rows = []
    scanned_vma_rss_kb = 0
    for idx, vma in enumerate(vmas):
        vma_rss_kb = rss_by_range.get((vma.start, vma.end), 0)
        scanned_vma_rss_kb += vma_rss_kb
        stats = windows[idx].stats(args.t)
        total.merge(stats)
        if stats.total_reported > 0 or vma_rss_kb > 0:
            rows.append((vma, stats, vma_rss_kb))
        write_page_rows(
            page_writer,
            sample_no,
            vma,
            windows[idx],
            args.t,
            args.loop,
            args.page_include_holes,
            args.page_rounds,
        )
    return total, rows, scanned_vma_rss_kb


def ratio(part, whole):
    if whole <= 0:
        return 0.0
    return part / whole


def print_summary(sample_no, total, pid, elapsed, scanned_vma_rss_kb):
    rss_kb = read_status_kb(pid, "VmRSS")
    swap_kb = read_status_kb(pid, "VmSwap")
    majflt = read_major_faults(pid)
    present_kb = total.present / 1024
    print(
        "sample={sample} elapsed={elapsed:.1f}s "
        "hot={hot:.1f}MB cold={cold:.1f}MB other={other:.1f}MB holes={holes:.1f}MB "
        "present={present:.1f}MB scanned_vma_rss={scanned_rss:.1f}MB "
        "scan_rss_ratio={scan_rss_ratio:.1%} process_rss={rss:.1f}MB "
        "process_coverage={process_coverage:.1%} swap={swap:.1f}MB majflt={majflt}".format(
            sample=sample_no,
            elapsed=elapsed,
            hot=bytes_to_mb(total.hot),
            cold=bytes_to_mb(total.cold),
            other=bytes_to_mb(total.other),
            holes=bytes_to_mb(total.hole),
            present=bytes_to_mb(total.present),
            scanned_rss=scanned_vma_rss_kb / 1024,
            scan_rss_ratio=ratio(present_kb, scanned_vma_rss_kb),
            rss=rss_kb / 1024,
            process_coverage=ratio(present_kb, rss_kb),
            swap=swap_kb / 1024,
            majflt=majflt,
        )
    )
    print(f"  cold_ratio={ratio(total.cold, total.present):.1%} (cold / scanned present pages)")


def print_top_vmas(rows, top_n):
    ranked = sorted(rows, key=lambda item: (item[1].cold, item[1].present, item[2]), reverse=True)
    for idx, (vma, stats, rss_kb) in enumerate(ranked[:top_n], start=1):
        print(
            "  #{idx:<2} cold={cold:8.1f}MB hot={hot:8.1f}MB present={present:8.1f}MB "
            "smaps_rss={rss:8.1f}MB ratio={ratio:6.1%} "
            "range={start:x}-{end:x} perms={perms} path={path}".format(
                idx=idx,
                cold=bytes_to_mb(stats.cold),
                hot=bytes_to_mb(stats.hot),
                present=bytes_to_mb(stats.present),
                rss=rss_kb / 1024,
                ratio=ratio(stats.cold, stats.present),
                start=vma.start,
                end=vma.end,
                perms=vma.perms,
                path=vma.label,
            )
        )


def csv_writer(path, fieldnames):
    if not path:
        return None, None
    f = open(path, "w", newline="", encoding="ascii")
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    return f, writer


def write_summary_row(writer, sample_no, total, pid, elapsed, scanned_vma_rss_kb):
    if writer is None:
        return
    rss_kb = read_status_kb(pid, "VmRSS")
    present_kb = total.present / 1024
    writer.writerow(
        {
            "sample": sample_no,
            "elapsed_sec": f"{elapsed:.3f}",
            "hot_mb": f"{bytes_to_mb(total.hot):.3f}",
            "cold_mb": f"{bytes_to_mb(total.cold):.3f}",
            "other_mb": f"{bytes_to_mb(total.other):.3f}",
            "hole_mb": f"{bytes_to_mb(total.hole):.3f}",
            "present_mb": f"{bytes_to_mb(total.present):.3f}",
            "scanned_vma_rss_mb": f"{scanned_vma_rss_kb / 1024:.3f}",
            "scan_rss_ratio": f"{ratio(present_kb, scanned_vma_rss_kb):.6f}",
            "process_coverage": f"{ratio(present_kb, rss_kb):.6f}",
            "cold_ratio": f"{ratio(total.cold, total.present):.6f}",
            "rss_mb": f"{rss_kb / 1024:.3f}",
            "swap_mb": f"{read_status_kb(pid, 'VmSwap') / 1024:.3f}",
            "major_faults": read_major_faults(pid),
        }
    )


def write_vma_rows(writer, sample_no, rows):
    if writer is None:
        return
    for vma, stats, rss_kb in rows:
        writer.writerow(
            {
                "sample": sample_no,
                "start": f"{vma.start:x}",
                "end": f"{vma.end:x}",
                "perms": vma.perms,
                "path": vma.label,
                "hot_mb": f"{bytes_to_mb(stats.hot):.3f}",
                "cold_mb": f"{bytes_to_mb(stats.cold):.3f}",
                "other_mb": f"{bytes_to_mb(stats.other):.3f}",
                "hole_mb": f"{bytes_to_mb(stats.hole):.3f}",
                "present_mb": f"{bytes_to_mb(stats.present):.3f}",
                "smaps_rss_mb": f"{rss_kb / 1024:.3f}",
                "scan_rss_ratio": f"{ratio(stats.present / 1024, rss_kb):.6f}",
                "cold_ratio": f"{ratio(stats.cold, stats.present):.6f}",
            }
        )


def format_round_states(round_states, loop):
    if not round_states:
        return ""
    return ";".join(round_states.get(idx, "") for idx in range(loop))


def write_page_rows(writer, sample_no, vma, window, threshold, loop, include_holes, include_rounds):
    if writer is None:
        return
    for page in window.iter_pages(include_holes):
        round_states = window.round_states.get(page, {})
        writer.writerow(
            {
                "sample": sample_no,
                "vma_start": f"{vma.start:x}",
                "vma_end": f"{vma.end:x}",
                "page_addr": f"{page * PAGE_SIZE:x}",
                "page_index": page,
                "page_size_kb": PAGE_SIZE // 1024,
                "class": window.page_class(page, threshold),
                "access_count": window.access_counts.get(page, 0),
                "round_states": format_round_states(round_states, loop) if include_rounds else "",
                "perms": vma.perms,
                "path": vma.label,
            }
        )


def ensure_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(f"target PID {pid} is not alive")
    except PermissionError:
        raise SystemExit(f"no permission to inspect PID {pid}; run as root")


def main():
    args = parse_args()
    if args.loop < 1:
        raise SystemExit("--loop must be >= 1")
    if args.interval < 0:
        raise SystemExit("--interval must be >= 0")
    if args.sleep < 0:
        raise SystemExit("--sleep must be >= 0")
    if args.t < 0:
        raise SystemExit("--t must be >= 0")
    if args.t > args.loop * WRITE_WEIGHT:
        raise SystemExit("--t must be <= --loop * 3, matching etmem slide's write-access weight")
    if args.page_rounds and not args.page_csv:
        raise SystemExit("--page-rounds requires --page-csv")
    if args.page_include_holes and not args.page_csv:
        raise SystemExit("--page-include-holes requires --page-csv")
    if os.geteuid() != 0:
        raise SystemExit("run as root; /proc/<pid>/idle_pages requires elevated privileges")
    ensure_alive(args.pid)
    idle_path = f"/proc/{args.pid}/idle_pages"
    if not os.path.exists(idle_path):
        raise SystemExit(f"{idle_path} does not exist; load etmem_scan or use an etmem-capable kernel")
    print(
        f"scan config: loop={args.loop} sleep={args.sleep}s interval={args.interval}s "
        f"T={args.t} weights=read:{READ_WEIGHT},dirty:{WRITE_WEIGHT}"
    )

    summary_f, summary_writer = csv_writer(
        args.csv,
        (
            "sample",
            "elapsed_sec",
            "hot_mb",
            "cold_mb",
            "other_mb",
            "hole_mb",
            "present_mb",
            "scanned_vma_rss_mb",
            "scan_rss_ratio",
            "process_coverage",
            "cold_ratio",
            "rss_mb",
            "swap_mb",
            "major_faults",
        ),
    )
    vma_f, vma_writer = csv_writer(
        args.vma_csv,
        (
            "sample",
            "start",
            "end",
            "perms",
            "path",
            "hot_mb",
            "cold_mb",
            "other_mb",
            "hole_mb",
            "present_mb",
            "smaps_rss_mb",
            "scan_rss_ratio",
            "cold_ratio",
        ),
    )
    page_f, page_writer = csv_writer(
        args.page_csv,
        (
            "sample",
            "vma_start",
            "vma_end",
            "page_addr",
            "page_index",
            "page_size_kb",
            "class",
            "access_count",
            "round_states",
            "perms",
            "path",
        ),
    )

    start_time = time.time()
    try:
        if args.warmup:
            print("warmup scan: clears accessed bits and establishes the observation window")
            scan_process(args.pid, args)

        sample_no = 1
        while args.watch or args.samples == 0 or sample_no <= args.samples:
            ensure_alive(args.pid)
            if args.interval > 0:
                time.sleep(args.interval)
            total, rows, scanned_vma_rss_kb = scan_process_window(args.pid, args, page_writer, sample_no)
            elapsed = time.time() - start_time
            print_summary(sample_no, total, args.pid, elapsed, scanned_vma_rss_kb)
            print_top_vmas(rows, args.top)
            write_summary_row(summary_writer, sample_no, total, args.pid, elapsed, scanned_vma_rss_kb)
            write_vma_rows(vma_writer, sample_no, rows)
            if summary_f:
                summary_f.flush()
            if vma_f:
                vma_f.flush()
            if page_f:
                page_f.flush()
            sample_no += 1
    except KeyboardInterrupt:
        print("\ninterrupted; exiting monitor")
    finally:
        if summary_f:
            summary_f.close()
        if vma_f:
            vma_f.close()
        if page_f:
            page_f.close()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
