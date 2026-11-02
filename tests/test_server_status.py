from concurrent.futures import ThreadPoolExecutor
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
        self.load = self.monitor()
        self.write_sample()

    def tearDown(self):
        self.temp.cleanup()

    def monitor(self, bandwidth=None):
        return ServerLoad(self.proc, lambda: self.time, lambda: 2000000000+self.time, bandwidth)

    def write_sample(self, cpu='100 0 50 800 50 0 0 0 20 0', tx=2000, interface='eth0', available=400):
        (self.proc/'stat').write_text('cpu  '+cpu+'\n')
        (self.proc/'meminfo').write_text('MemTotal: 1000 kB\nMemAvailable: '+str(available)+' kB\n')
        (self.proc/'net/route').write_text('Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n'+
            interface+' 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n')
        (self.proc/'net/dev').write_text('Inter-| Receive | Transmit\n face | bytes | bytes\n'+
            'lo: 999999 0 0 0 0 0 0 0 999999 0 0 0 0 0 0 0\n'+
            interface+': 1000 0 0 0 0 0 0 0 '+str(tx)+' 0 0 0 0 0 0 0\n')

    def test_cached_public_status_omits_resource_details_and_excludes_guest_cpu(self):
        first = self.load.snapshot()
        self.assertEqual(first['status'],'unknown')
        self.write_sample('130 0 50 870 50 0 0 0 1000 0')
        self.time = 9.9
        self.assertIs(self.load.snapshot(), first)
        self.time = 10
        with ThreadPoolExecutor(max_workers=8) as pool:
            snapshots = list(pool.map(lambda _: self.load.snapshot(), range(16)))
        current = snapshots[0]
        self.assertTrue(all(value is current for value in snapshots))
        self.assertEqual(current,dict(status='green',label='正常',sampled_at=2000000010,refresh_after_seconds=10))

    def test_cpu_pressure_changes_at_seventy_and_ninety_percent(self):
        self.load.snapshot()
        for at,cpu,status in [(10,'169 0 50 831 50 0 0 0','green'),
                              (20,'239 0 50 861 50 0 0 0','yellow'),
                              (30,'329 0 50 871 50 0 0 0','red')]:
            self.write_sample(cpu)
            self.time = at
            self.assertEqual(self.load.snapshot()['status'],status)

    def test_memory_pressure_can_raise_the_combined_level(self):
        self.load.snapshot()
        for at,cpu,available,status in [(10,'130 0 50 870 50 0 0 0',100,'red'),
                (20,'160 0 50 940 50 0 0 0',300,'yellow'),(30,'190 0 50 1010 50 0 0 0',400,'green')]:
            self.write_sample(cpu,available=available)
            self.time = at
            self.assertEqual(self.load.snapshot()['status'],status)

    def test_configured_outbound_bandwidth_raises_the_level_without_public_counters(self):
        self.load = self.monitor(1)
        self.load.snapshot()
        tx = 2000
        for at,cpu,increment,status in [(10,'130 0 50 870 50 0 0 0',1125000,'red'),
                (20,'160 0 50 940 50 0 0 0',875000,'yellow'),(30,'190 0 50 1010 50 0 0 0',500000,'green')]:
            tx += increment
            self.write_sample(cpu,tx=tx)
            self.time = at
            current = self.load.snapshot()
            self.assertEqual(current['status'],status)
            self.assertEqual(set(current),{'status','label','sampled_at','refresh_after_seconds'})

    def test_unavailable_or_reset_counters_do_not_report_a_green_state(self):
        self.load = self.monitor(1)
        self.load.snapshot()
        self.write_sample('130 0 50 870 50 0 0 0',tx=500,interface='ens3')
        self.time = 10
        self.assertEqual(self.load.snapshot()['status'],'unknown')
        self.write_sample('160 0 50 940 50 0 0 0',tx=100,interface='ens3')
        self.time = 20
        self.assertEqual(self.load.snapshot()['status'],'unknown')
        (self.proc/'stat').unlink()
        (self.proc/'meminfo').write_text('MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 200 kB\nSReclaimable: 80 kB\nShmem: 30 kB\n')
        self.time = 30
        self.assertEqual(self.load.memory(),60)
        self.assertEqual(self.load.snapshot()['status'],'unknown')


if __name__ == '__main__':
    unittest.main()
