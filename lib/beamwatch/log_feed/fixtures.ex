defmodule BeamWatch.LogFeed.Fixtures do
  @moduledoc false

  alias BeamWatch.LogFeed.Entry

  @base_at ~U[2026-06-05 15:00:00Z]

  def sample_streams do
    [
      container_restart_loop(),
      disk_smart_warning(),
      share_permission_failure(),
      vm_boot_failure()
    ]
  end

  def validation_streams do
    [
      baseline(),
      container_restart_loop(),
      disk_smart_warning(),
      share_permission_failure(),
      vm_boot_failure(),
      benign_container_restart(),
      benign_disk_operations(),
      benign_share_operations(),
      benign_vm_operations(),
      malformed_input()
    ]
  end

  defp baseline do
    {"baseline",
     [
       entry("graphql-api.log", 20, 1, "[INFO ApiServer]: GraphQL endpoint ready port=4000"),
       entry("syslog.log", 20, 2, "emhttpd: Array Started"),
       entry("unraid-dev.log", 20, 3, "[info] [Unraid.State] Array state changed state=STARTED"),
       entry("docker.log", 20, 4, "container=plex event=start"),
       entry("app.log", 20, 8, "service=plex healthcheck passed path=/identity request_id=base-1")
     ]}
  end

  defp container_restart_loop do
    {"container_restart_loop:plex",
     [
       entry("docker.log", 100, 240, "container=plex event=die exit_code=137"),
       entry(
         "app.log",
         100,
         244,
         "service=plex healthcheck failed path=/identity request_id=plex-a"
       ),
       entry("docker.log", 100, 248, "container=plex event=start"),
       entry("nginx.log", 100, 250, "upstream plex unavailable request_id=plex-b"),
       entry("docker.log", 100, 255, "container=plex event=die exit_code=137"),
       entry("docker.log", 100, 262, "container=plex event=start"),
       entry("docker.log", 100, 274, "container=plex event=die exit_code=137"),
       entry("docker.log", 100, 280, "container=plex event=start"),
       entry("docker.log", 100, 295, "container=plex event=die exit_code=137"),
       entry("docker.log", 100, 300, "container=plex event=start"),
       entry(
         "app.log",
         100,
         315,
         "service=plex healthcheck passed path=/identity request_id=plex-c"
       )
     ]}
  end

  defp disk_smart_warning do
    {"disk_smart_warning:disk3",
     [
       entry(
         "syslog.log",
         80,
         360,
         "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
       ),
       entry(
         "syslog.log",
         80,
         378,
         "emhttpd: disk3 SMART warning: Current_Pending_Sector raw=2 threshold=0"
       ),
       entry("syslog.log", 80, 1_500, "emhttpd: disk3 SMART check passed")
     ]}
  end

  defp share_permission_failure do
    denied = "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"

    {"share_permission_failure:media",
     [
       entry("smb.log", 80, 420, denied),
       entry("nfs.log", 80, 426, "nfsd: permission denied share=media client=192.168.1.12"),
       entry("smb.log", 80, 420, denied),
       entry("smb.log", 80, 438, denied)
     ]}
  end

  defp vm_boot_failure do
    {"vm_boot_failure:windows11",
     [
       entry(
         "libvirt.log",
         100,
         480,
         "vm=windows11 action=start status=failed reason=\"cannot access storage image /mnt/user/domains/windows11/vdisk1.img\""
       ),
       entry("syslog.log", 100, 482, "kernel: br0: port missing for vm=windows11"),
       entry(
         "qemu.log",
         100,
         484,
         "qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img: Permission denied"
       ),
       entry("libvirt.log", 100, 720, "vm=windows11 action=start status=starting"),
       entry("qemu.log", 100, 723, "qemu-system-x86_64: started vm=windows11 pid=18420"),
       entry("libvirt.log", 100, 728, "vm=windows11 action=start status=running")
     ]}
  end

  defp benign_container_restart do
    {"benign_container_restart:home-assistant",
     [
       entry("docker.log", 60, 540, "container=home-assistant event=die exit_code=0"),
       entry("docker.log", 60, 545, "container=home-assistant event=start"),
       entry(
         "app.log",
         60,
         552,
         "service=home-assistant healthcheck passed path=/api/ request_id=ha-1"
       )
     ]}
  end

  defp benign_disk_operations do
    {"benign_disk_operations:disk1",
     [
       entry(
         "unraid-dev.log",
         60,
         600,
         "Running smartctl: /usr/sbin/smartctl -n standby -H /dev/nvme0n1"
       ),
       entry(
         "unraid-dev.log",
         60,
         603,
         "smartctl exited with code 0: SMART overall-health self-assessment test result: PASSED device=/dev/nvme0n1"
       ),
       entry("syslog.log", 60, 610, "emhttpd: disk1 SMART check passed"),
       entry("syslog.log", 60, 630, "emhttpd: spinning down disk1")
     ]}
  end

  defp benign_share_operations do
    {"benign_share_operations:backups",
     [
       entry(
         "smb.log",
         60,
         660,
         "smbd[8220]: user=alex opened share=backups path=/mnt/user/backups"
       ),
       entry(
         "nfs.log",
         60,
         663,
         "nfsd: client=192.168.1.18 mounted share=backups export=/mnt/user/backups"
       ),
       entry("smb.log", 60, 668, "smbd[8220]: user=alex closed share=backups bytes_read=18452224")
     ]}
  end

  defp benign_vm_operations do
    {"benign_vm_operations:debian-dev",
     [
       entry("libvirt.log", 60, 780, "vm=debian-dev action=start status=running"),
       entry("libvirt.log", 60, 900, "vm=debian-dev action=shutdown reason=user_request"),
       entry("qemu.log", 60, 906, "qemu-system-x86_64: terminating on signal 15 from pid 1882")
     ]}
  end

  defp malformed_input do
    {"malformed_input",
     [
       line("app.log", 40, "not-a-timestamp service=plex healthcheck"),
       line("syslog.log", 40, "#{timestamp(960)} emhttpd: disk="),
       line("qemu.log", 40, "#{timestamp(965)} qemu-system-x86_64: -drive file="),
       line("smb.log", 40, "2026-06-05T15:16")
     ]}
  end

  defp entry(source, delay_ms, offset_seconds, payload) do
    line(source, delay_ms, "#{timestamp(offset_seconds)} #{payload}")
  end

  defp line(source, delay_ms, payload) do
    %Entry{source: source, delay_ms: delay_ms, line: payload}
  end

  defp timestamp(offset_seconds) do
    @base_at
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.to_iso8601()
  end
end
