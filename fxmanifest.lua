fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cipher-trucking'
author 'XyraL'
description 'Cipher — Trucking. Civilian delivery-job loop for QBox/QBCore.'
version '2.0.2'

-- Works on QBox (qbx_core) OR QBCore (qb-core). The bridge auto-detects.
dependencies {
    'ox_lib',
    'ox_target',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'bridge/framework.lua',
    'client/main.lua',
    -- After main.lua: reads its truckEntity/trailerEntity globals.
    'client/fuel.lua',
    'client/company.lua',
    'client/admin.lua',
    -- Last: it counts what everything above registered.
    'client/diag.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/framework.lua',
    -- db.lua first: it owns the schema and everything below gates on the
    -- DBReady flag it sets. settings.lua next — it reads that schema on boot
    -- and everything after it resolves tunables through SGet().
    'server/db.lua',
    'server/settings.lua',
    'server/company.lua',
    -- maintenance before main.lua, which calls Maintenance.* on job
    -- completion and when building the garage payload.
    'server/maintenance.lua',
    'server/admin.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/map.js',
    'html/js/app.js',
    'html/js/admin.js',
}
