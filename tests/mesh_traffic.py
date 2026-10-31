#!/usr/bin/env python3
"""Paced UDP echo measurements. Each process measures its own monotonic RTT.

Synthetic traffic only: the packet rate is a test parameter, not a Civ6 trace.
Run one echo and one benchmark per independent client network namespace.
"""
import argparse
from collections import deque
import json
from pathlib import Path
import select
import signal
import socket
import struct
import time

HEADER = struct.Struct('!4sIIQ')


def echo(stats=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', 62056))
    seen, order = set(), deque()
    counts = dict(requests=0, duplicates_delivered_to_game_socket=0)
    if stats:
        signal.signal(signal.SIGUSR1, lambda *_: Path(stats).write_text(json.dumps(counts)))
    while True:
        packet, peer = sock.recvfrom(2048)
        if stats and len(packet) >= HEADER.size:
            identity = (peer, HEADER.unpack_from(packet))
            counts['requests'] += 1
            if identity in seen:
                counts['duplicates_delivered_to_game_socket'] += 1
            else:
                seen.add(identity)
                order.append(identity)
                if len(order) > 10000:
                    seen.remove(order.popleft())
        sock.sendto(packet, peer)


def bench(args):
    targets = args.peers.split(',')
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, 0))
    sock.setblocking(False)
    period = 1 / args.pps
    # Spread peers and senders through the period instead of creating an
    # artificial 30-packet synchronized burst at the relay every second.
    next_send = {ip: args.start + (j + args.node / 6) * period / len(targets)
                 for j, ip in enumerate(targets)}
    sent = {ip: [] for ip in targets}
    pending = {}
    sequence = 0
    end = args.start + args.duration
    padding = b'G' * (args.payload - HEADER.size)
    while time.monotonic() < end + 2:
        now = time.monotonic()
        for ip in targets:
            if next_send[ip] < end and next_send[ip] <= now:
                stamp = time.monotonic_ns()
                packet = HEADER.pack(b'C6NT', args.node, sequence, stamp) + padding
                sock.sendto(packet, (ip, 62056))
                sample = [round(stamp / 1e9 - args.start, 6), None]
                sent[ip].append(sample)
                pending[sequence] = (ip, stamp, sample)
                sequence += 1
                next_send[ip] += period
        future = [x for x in next_send.values() if x < end]
        timeout = max(0, min(.05, min(future) - time.monotonic())) if future else .05
        if select.select([sock], [], [], timeout)[0]:
            while True:
                try:
                    packet, peer = sock.recvfrom(2048)
                except BlockingIOError:
                    break
                received = time.monotonic_ns()
                if len(packet) < HEADER.size:
                    continue
                magic, node, seq, stamp = HEADER.unpack_from(packet)
                entry = pending.get(seq)
                if magic == b'C6NT' and node == args.node and entry and entry[:2] == (peer[0], stamp):
                    entry[2][1] = round((received - stamp) / 1e6, 3)
                    del pending[seq]
    result = dict(node=args.node, start=args.start, duration=args.duration,
                  pps_per_peer=args.pps, payload_bytes=args.payload, flows=sent)
    Path(args.output).write_text(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    echo_parser = commands.add_parser('echo')
    echo_parser.add_argument('--stats')
    p = commands.add_parser('bench')
    p.add_argument('--node', type=int, required=True)
    p.add_argument('--bind', required=True)
    p.add_argument('--peers', required=True)
    p.add_argument('--start', type=float, required=True)
    p.add_argument('--duration', type=float, required=True)
    p.add_argument('--pps', type=float, required=True)
    p.add_argument('--payload', type=int, required=True)
    p.add_argument('--output', required=True)
    args = parser.parse_args()
    if args.mode == 'echo':
        echo(args.stats)
    else:
        bench(args)
