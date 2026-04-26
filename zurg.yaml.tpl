zurg: v1
token: ${RD_API_TOKEN}
host: "[::]"
port: 9999
check_for_changes_every_secs: 10
enable_repair: true
repair_every_mins: 60
rar_action: extract

directories:
  movies:
    group: media
    group_order: 10
    filters:
      - regex: /.*/
  shows:
    group: media
    group_order: 20
    filters:
      - regex: /.*/
