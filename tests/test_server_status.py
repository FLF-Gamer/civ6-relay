from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from keyservice import ServerLoad


class ServerLoadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.proc = Path(self.temp.name)
        (self.proc/'net').mkdir()
        self.time = 0
        self.load = ServerLoad(self.proc, lambda: self.time, lambda: 2000000000+self.time)
        self.write_sample()

    def tearDown(self):
        self.temp.cleanup()

    def write_sample(self, cpu='100 0 50 800 50 0 0 0 20 0', rx=1000, tx=2000, interface='eth0'):
        (self.proc/'stat').write_text('cpu  '+cpu+'\n')
        (self.proc/'meminfo').write_text('MemTotal: 1000 kB\nMemAvailable: 400 kB\n')
        (self.proc/'net/route').write_text('Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n'+
            interface+' 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n')
        (self.proc/'net/dev').write_text('Inter-| Receive | Transmit\n face | bytes | bytes\n'+
            'lo: 999999 0 0 0 0 0 0 0 999999 0 0 0 0 0 0 0\n'+
            interface+': '+str(rx)+' 0 0 0 0 0 0 0 '+str(tx)+' 0 0 0 0 0 0 0\n')

    def test_cached_host_sample_uses_deltas_and_excludes_guest_cpu_and_loopback(self):
        first = self.load.snapshot()
        self.assertIsNone(first['cpu_percent'])
        self.assertIsNone(first['network_rx_bps'])
        self.assertEqual(first['memory_percent'], 60)
        self.write_sample('120 0 60 860 60 0 0 0 70 0', rx=11000, tx=22000)
        self.time = 9.9
        self.assertIs(self.load.snapshot(), first)
        self.time = 10
        with ThreadPoolExecutor(max_workers=8) as pool:
            snapshots = list(pool.map(lambda _: self.load.snapshot(), range(16)))
        current = snapshots[0]
        self.assertTrue(all(value is current for value in snapshots))
        self.assertEqual(current['cpu_percent'], 30)
        self.assertEqual(current['network_rx_bps'], 8000)
        self.assertEqual(current['network_tx_bps'], 16000)
        self.assertEqual(current['sample_seconds'], 10)
        self.assertEqual(current['sampled_at'], 2000000010)
        self.assertEqual(current['refresh_after_seconds'], 10)
        json.dumps(current)

    def test_interface_changes_and_counter_resets_do_not_invent_network_traffic(self):
        self.load.snapshot()
        self.write_sample(rx=500, tx=600, interface='ens3')
        self.time = 10
        current = self.load.snapshot()
        self.assertEqual(current['network_interface'], 'ens3')
        self.assertIsNone(current['network_rx_bps'])
        self.write_sample(rx=100, tx=200, interface='ens3')
        self.time = 20
        self.assertEqual(self.load.snapshot()['network_rx_bps'], 0)

    def test_missing_host_metrics_are_unknown_and_memory_has_an_older_kernel_fallback(self):
        (self.proc/'stat').unlink()
        (self.proc/'net/route').unlink()
        (self.proc/'meminfo').write_text('MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 200 kB\nSReclaimable: 80 kB\nShmem: 30 kB\n')
        current = self.load.snapshot()
        self.assertIsNone(current['cpu_percent'])
        self.assertIsNone(current['network_interface'])
        self.assertEqual(current['memory_used_bytes'], 600*1024)
        (self.proc/'meminfo').unlink()
        self.time = 10
        self.assertIsNone(self.load.snapshot()['memory_percent'])


if __name__ == '__main__':
    unittest.main()
