-- ─────────────────────────────────────────────────────────────
-- Company invites
-- ox_target on nearby player peds — always offered; the server is the real
-- gate (no company, no invite permission, target already in a company,
-- etc. are all rejected there with a clear message). Not worth the extra
-- moving parts of syncing a client-side permission cache just to hide the
-- option — a rejection notification is a fine fallback.
-- ─────────────────────────────────────────────────────────────
CreateThread(function()
    exports.ox_target:addGlobalPlayer({
        {
            name = 'cipher_trucking_company_invite',
            icon = 'fas fa-user-plus',
            label = 'Invite to Company',
            distance = 3.0,
            onSelect = function(data)
                local targetPed = data.entity
                if not targetPed or not DoesEntityExist(targetPed) then return end

                local playerIndex = NetworkGetPlayerIndexFromPed(targetPed)
                local targetSrc = GetPlayerServerId(playerIndex)
                if not targetSrc or targetSrc <= 0 then return end

                local ok, err = lib.callback.await('cipher-trucking:server:companyInvite', false, targetSrc)
                if not ok then
                    lib.notify({ description = err or 'Could not send invite.', type = 'error' })
                end
            end,
        },
    })
end)

RegisterNetEvent('cipher-trucking:client:companyInvite', function(data)
    local choice = lib.alertDialog({
        header = 'Company Invite',
        content = ('%s invited you to join %s.'):format(data.from or 'Someone', data.company or 'a company'),
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })

    if choice ~= 'confirm' then return end

    local ok, err = lib.callback.await('cipher-trucking:server:companyAcceptInvite', false)
    if ok then
        lib.notify({ description = 'You joined the company.', type = 'success' })
    else
        lib.notify({ description = err or 'Could not accept invite.', type = 'error' })
    end
end)
