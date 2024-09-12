-- Import menu elements
local menu = require("menu")
local revive = require("data.revive")
local explorer = require("data.explorer")
local automindcage = require("data.automindcage")
local actors = require("data.actors")
local object_interaction = require("data.object_interaction")

-- Função para randomizar waypoints
local function randomize_waypoint(waypoint, max_offset)
    max_offset = max_offset or 1.5 -- Valor padrão de 1.5 metros
    local random_x = math.random() * max_offset * 2 - max_offset
    local random_y = math.random() * max_offset * 2 - max_offset
    
    return vec3:new(
        waypoint:x() + random_x,
        waypoint:y() + random_y,
        waypoint:z()
    )
end

-- Inicializa as variáveis
local waypoints = {}
local plugin_enabled = false
local initialMessageDisplayed = false
local loopEnabled = false -- Variável para armazenar o estado do loop
local ni = 1
local start_time = 0
local check_interval = 120 -- Tempo que ele vai entrar no mapa para explorar e ver se consegue cinders
local current_city_index = 1
local is_moving = false
local teleporting = false
local next_teleport_attempt_time = 0 -- Variável para a próxima tentativa de teleporte
local loading_start_time = nil -- Variável para marcar o início da tela de carregamento
local returning_to_failed = false -- Variável para indicar se está retornando a um waypoint falhado
local moving_backwards = false -- Variável para indicar se o movimento é para trás
local graphics_enabled = false -- Variável para habilitar/desabilitar gráficos
local stuck_check_time = 0
local stuck_threshold = 10 -- Tempo parado para ativar o explorer
local explorer_active = false
local stuck_check_time = os.clock()
local moveThreshold = 12 -- Valor padrão

-- Novas variáveis para controle de movimento
local last_movement_time = 0
local force_move_cooldown = 0
local previous_player_pos = nil -- Variável para armazenar a posição anterior do jogador

local function update_explorer_target()
    if explorer and current_waypoint then
        explorer.set_target(current_waypoint)
    end
end

-- Add the cleanup_after_helltide function
local function cleanup_after_helltide()
    console.print("Performing general cleanup after Helltide...")

    -- Reset movement variables
    is_moving = false
    teleporting = false
    explorer_active = false
    moving_backwards = false

    -- Clear waypoints and related variables
    waypoints = {}
    ni = 1

    -- Reset timers
    start_time = 0
    next_teleport_attempt_time = 0
    loading_start_time = nil
    stuck_check_time = os.clock()
    last_movement_time = 0
    force_move_cooldown = 0

    -- Reset player position tracking
    previous_player_pos = nil

    -- Reset explorer module
    if explorer and explorer.disable then
        explorer.disable()
    end

    -- Clear object_interaction blacklist
    object_interaction.clear_blacklist()

    -- Force garbage collection
    collectgarbage("collect")

    console.print("Cleanup completed.")
end

-- Lista de cidades e waypoints
local helltide_tps = {
    {name = "Frac_Tundra_S", id = 0xACE9B, file = "menestad"},
    {name = "Scos_Coast", id = 0x27E01, file = "marowen"},
    {name = "Kehj_Oasis", id = 0xDEAFC, file = "ironwolfs"},
    {name = "Hawe_Verge", id = 0x9346B, file = "wejinhani"},
    {name = "Step_South", id = 0x462E2, file = "jirandai"}
}

-- Função para carregar waypoints do arquivo selecionado
local function load_waypoints(file)
    if file == "wejinhani" then
        waypoints = require("waypoints.wejinhani")
        console.print("Loaded waypoints: wejinhani")
    elseif file == "marowen" then
        waypoints = require("waypoints.marowen")
        console.print("Loaded waypoints: marowen")
    elseif file == "menestad" then
        waypoints = require("waypoints.menestad")
        console.print("Loaded waypoints: menestad")
    elseif file == "jirandai" then
        waypoints = require("waypoints.jirandai")
        console.print("Loaded waypoints: jirandai")
    elseif file == "ironwolfs" then
        waypoints = require("waypoints.ironwolfs")
        console.print("Loaded waypoints: ironwolfs")
    else
        console.print("No waypoints loaded")
    end
end

-- Função para verificar a cidade atual e carregar os waypoints
local function check_and_load_waypoints()
    local world_instance = world.get_current_world()
    if world_instance then
        local zone_name = world_instance:get_current_zone_name()

        for _, tp in ipairs(helltide_tps) do
            if zone_name == tp.name then
                load_waypoints(tp.file)
                current_city_index = tp.id -- Atualiza o índice da cidade atual
                return
            end
        end
        console.print("No matching city found for waypoints")
    end
end

-- Função para obter a distância entre o jogador e um ponto
local function get_distance(point)
    return get_player_position():dist_to(point)
end

-- Função de movimento principal modificada
local function pulse()
    if not plugin_enabled or object_interaction.is_interacting() or not is_moving then
        return
    end

    if type(waypoints) ~= "table" then
        console.print("Error: waypoints is not a table")
        return
    end

    if type(ni) ~= "number" then
        console.print("Error: ni is not a number")
        return
    end

    if ni > #waypoints or ni < 1 or #waypoints == 0 then
        if loopEnabled then
            ni = 1
        else
            return
        end
    end

    current_waypoint = waypoints[ni]
    if current_waypoint then
        local current_time = os.clock()
        local player_pos = get_player_position()
        local distance = get_distance(current_waypoint)
        
        if distance < 2 then
            if moving_backwards then
                ni = ni - 1
            else
                ni = ni + 1
            end
            last_movement_time = current_time
            force_move_cooldown = 0
            previous_player_pos = player_pos
            stuck_check_time = current_time
        else
            if not explorer_active then
                if current_time - stuck_check_time > stuck_threshold and not teleporting then
                    console.print("Player stuck for 10 seconds, calling explorer module")
                    explorer.set_target(current_waypoint)
                    explorer.enable()
                    explorer_active = true
                    return
                end

                if previous_player_pos and player_pos:dist_to(previous_player_pos) < 3 then -- estava 0.1 coloquei 3
                    if current_time - last_movement_time > 5 then
                        console.print("Player stuck, using force_move_raw")
                        local randomized_waypoint = randomize_waypoint(current_waypoint)
                        pathfinder.force_move_raw(randomized_waypoint)
                        last_movement_time = current_time
                    end
                else
                    previous_player_pos = player_pos
                    last_movement_time = current_time
                    stuck_check_time = current_time -- Reset stuck_check_time when moving
                end

                if current_time > force_move_cooldown then
                    local randomized_waypoint = randomize_waypoint(current_waypoint)
                    pathfinder.request_move(randomized_waypoint)
                end
            end
        end
    end
end

-- Função para verificar se o jogo está na tela de carregamento
local function is_loading_screen()
    local world_instance = world.get_current_world()
    if world_instance then
        local zone_name = world_instance:get_current_zone_name()
        return zone_name == nil or zone_name == ""
    end
    return true
end

-- Função para verificar se está na Helltide
local was_in_helltide = false

local function is_in_helltide(local_player)
    local buffs = local_player:get_buffs()
    for _, buff in ipairs(buffs) do
        if buff.name_hash == 1066539 then -- ID do buff de Helltide
            was_in_helltide = true
            return true
        end
    end
    return false
end

-- Função para iniciar a contagem de cinders e teletransporte
local function start_movement_and_check_cinders()
    if not is_moving then
        start_time = os.clock()
        is_moving = true
    end

    if os.clock() - start_time > check_interval then
        is_moving = false
        local cinders_count = get_helltide_coin_cinders()

        if cinders_count == 0 then
            console.print("No cinders found. Stopping movement to teleport.")
            local player_pos = get_player_position() -- Pega a posição atual do jogador
            pathfinder.request_move(player_pos) -- Move o jogador para sua posição atual para interromper o movimento
        else
            console.print("Cinders found. Continuing movement.")
        end
    end

    pulse()
end

-- Função chamada periodicamente para interagir com objetos
on_update(function()
    if plugin_enabled then
        if teleporting then
            local current_time = os.clock()
            local current_world = world.get_current_world()
            if not current_world then
                return
            end

            -- Verifica se estamos na tela de loading (Limbo)
            if current_world:get_name():find("Limbo") then
                if not loading_start_time then
                    loading_start_time = current_time
                end
                return
            else
                if loading_start_time and (current_time - loading_start_time) < 60 then
                    return
                end
                loading_start_time = nil
            end

            if not is_loading_screen() then
                local world_instance = world.get_current_world()
                if world_instance then
                    local zone_name = world_instance:get_current_zone_name()
                    if zone_name == helltide_tps[current_city_index].name then
                        load_waypoints(helltide_tps[current_city_index].file)
                        ni = 1
                        teleporting = false
                    elseif os.clock() > next_teleport_attempt_time then
                        console.print("Teleporting...")
                        teleport_to_waypoint(helltide_tps[current_city_index].id)
                        next_teleport_attempt_time = os.clock() + 30
                    end
                end
            end
        else
            local local_player = get_local_player()
            if local_player then
                local current_in_helltide = is_in_helltide(local_player)
                
                if was_in_helltide and not current_in_helltide then
                    console.print("Helltide ended. Performing cleanup.")
                    cleanup_after_helltide()
                    was_in_helltide = false
                end

                if current_in_helltide then
                    was_in_helltide = true
                    if explorer_active then
                        if not _G.explorer_active then
                            explorer_active = false
                            console.print("Explorer module finished, resuming normal movement")
                        end
                    else
                        if menu.profane_mindcage_toggle:get() then
                            automindcage.update()
                        end
                        object_interaction.update() -- Substitui checkInteraction() e interactWithObjects()
                        start_movement_and_check_cinders()
                        if menu.revive_enabled:get() then
                            revive.check_and_revive()
                        end
                        actors.update()
                    end
                else
                    console.print("Not in the Helltide zone. Loading Teleport. Wait...")
                    current_city_index = (current_city_index % #helltide_tps) + 1
                    
                    -- Remover o busy waiting loop
                    if os.clock() >= next_teleport_attempt_time then
                        teleport_to_waypoint(helltide_tps[current_city_index].id)
                        teleporting = true
                        next_teleport_attempt_time = os.clock() + 30 -- Reiniciar o temporizador para a próxima tentativa
                    end
                end
            end
        end
    end
end)

-- Função para renderizar o menu
on_render_menu(function()
    if menu.main_tree:push("HellChest Farmer (EletroLuz)-V1.4") then
        -- Renderiza o checkbox para habilitar o plugin de movimento
        local enabled = menu.plugin_enabled:get()
        if enabled ~= plugin_enabled then
            plugin_enabled = enabled
            if plugin_enabled then
                console.print("Movement Plugin enabled")
                check_and_load_waypoints()
                stuck_check_time = os.clock()
            else
                console.print("Movement Plugin disabled")
            end
        end
        menu.plugin_enabled:render("Enable Movement Plugin", "Enable or disable the movement plugin")

        -- Renderiza o checkbox para habilitar o plugin de abertura de baus
        local enabled_doors = menu.main_openDoors_enabled:get() or false
        if enabled_doors ~= doorsEnabled then
            doorsEnabled = enabled_doors
            console.print("Open Chests Plugin " .. (doorsEnabled and "enabled" or "disabled"))
        end
        menu.main_openDoors_enabled:render("Open Chests", "Enable or disable the chest plugin")

        -- Renderiza o checkbox para habilitar o loop dos waypoints
        local enabled_loop = menu.loop_enabled:get() or false
        if enabled_loop ~= loopEnabled then
            loopEnabled = enabled_loop
            console.print("Loop Waypoints " .. (loopEnabled and "enabled" or "disabled"))
        end
        menu.loop_enabled:render("Enable Loop", "Enable or disable looping waypoints")

        -- Renderiza o checkbox para habilitar/desabilitar o módulo de revive
        local enabled_revive = menu.revive_enabled:get() or false
        if enabled_revive ~= revive_enabled then
            revive_enabled = enabled_revive
            console.print("Revive Module " .. (revive_enabled and "enabled" or "disabled"))
        end
        menu.revive_enabled:render("Enable Revive Module", "Enable or disable the revive module")

        -- Cria um submenu para as configurações do Profane Mindcage
        if menu.profane_mindcage_tree:push("Profane Mindcage Settings") then
            -- Renderiza o checkbox para habilitar/desabilitar o Profane Mindcage
            local enabled_profane = menu.profane_mindcage_toggle:get() or false
            if enabled_profane ~= profane_mindcage_enabled then
                profane_mindcage_enabled = enabled_profane
                console.print("Profane Mindcage " .. (profane_mindcage_enabled and "enabled" or "disabled"))
            end
            menu.profane_mindcage_toggle:render("Enable Profane Mindcage Auto Use", "Enable or disable automatic use of Profane Mindcage")

            -- Renderiza o slider para o número de Profane Mindcages
            local profane_count = menu.profane_mindcage_slider:get()
            if profane_count ~= profane_mindcage_count then
                profane_mindcage_count = profane_count
                console.print("Profane Mindcage count set to " .. profane_mindcage_count)
            end
            menu.profane_mindcage_slider:render("Profane Mindcage Count", "Number of Profane Mindcages to use")

            menu.profane_mindcage_tree:pop()
        end

        -- Cria um submenu para as configurações do Move Threshold
        if menu.move_threshold_tree:push("Chest Move Range Settings") then
            if menu.move_threshold_slider then
                local move_threshold = menu.move_threshold_slider:get()
                if move_threshold ~= moveThreshold then
                    moveThreshold = move_threshold
                    console.print("Move Threshold set to " .. moveThreshold)
                end
                menu.move_threshold_slider:render("Move Range", "maximum distance the player can detect and move towards a chest in the game")
            else
                console.print("Error: move_threshold_slider is not initialized")
            end
            menu.move_threshold_tree:pop()
        end

        menu.main_tree:pop()
    end
end)