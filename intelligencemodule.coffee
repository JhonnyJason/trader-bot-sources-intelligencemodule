intelligencemodule = {name: "intelligencemodule"}
############################################################
#region printLogFunctions
log = (arg) ->
    if allModules.debugmodule.modulesToDebug["intelligencemodule"]?  then console.log "[intelligencemodule]: " + arg
    return
ostr = (obj) -> JSON.stringify(obj, null, 4)
olog = (obj) -> log "\n" + ostr(obj)
print = (arg) -> console.log(arg)
#endregion

############################################################
#region modulesFromEnvironment
performance = require("perf_hooks").performance

situationAnalyzer = null
budgetManager = null
network = null
state = null
cfg = null
utl = null

#endregion

############################################################
#region internalProperties
situations = null

############################################################
actionMemory = {} # will vanish after chillTimeMS
ideaMemory = {} # 
orderMemory = {} #

############################################################
newOrders = [] # is generated each cycle
newActions = [] # is generated each cycle

############################################################
#region configProperties
strategies = []

chillTimeMS = 0
cyclePeriodMS = 0
memoryDecayMS = 0
#endregion

#endregion

############################################################
intelligencemodule.initialize = ->
    log "intelligencemodule.initialize"
    situationAnalyzer = allModules.situationanalyzermodule
    situations = situationAnalyzer.situations

    budgetManager = allModules.budgetmanagermodule
    network = allModules.networkmodule
    state = allModules.persistentstatemodule
    utl = allModules.utilmodule

    cfg = allModules.configmodule
    chillTimeMS = cfg.intelligenceChillTimeM * 60 * 1000
    cyclePeriodMS = cfg.intelligenceCyclePeriodS * 1000
    memoryDecayMS = cfg.intelligenceMemoryDecayTimeM * 60 * 1000

    for strategy in cfg.intelligenceStrategies
        strategyModule = allModules[strategy]
        strategies.push strategyModule

    actionMemory = state.load("actionMemory")
    ideaMemory = state.load("ideaMemory")
    orderMemory = state.load("orderMemory")

    letForget(key, actionMemory, chillTimeMS) for key,action of actionMemory
    letForget(key, ideaMemory, memoryDecayMS) for key,idea of ideaMemory
    letForget(key, orderMemory, memoryDecayMS) for key,order of orderMemory
    return

############################################################
#region internalFunctions
processCycle = ->
    log "> processCycle"
    return unless situationAnalyzer.ready
    
    starttime = performance.now()

    perceiveNewSituation()
    recognizeOrderPlacementActionEffects()
    processIdeas()
    act()

    checkAlienBudgetUsage()

    afterActionTime = performance.now()

    saveMemory()

    endtime = performance.now()

    processingTime = afterActionTime - starttime
    savingTime = endtime - afterActionTime
    
    savingTime = savingTime.toFixed(3)
    processingTime = processingTime.toFixed(3)
    
    # log " - - - - - "
    # log "performance checking..." 
    # log "time used for state processing: " + processingTime + "ms" 
    # log "time used for memory saving: " + savingTime + "ms"
    return

############################################################
#region perceiveNewSituation
perceiveNewSituation = ->
    # log "perceiveNewSituation"
    for exchange in cfg.activeExchanges
        situation = situations[exchange]
        for assetPair,orders of situation.latestOrders
            for order in orders.buyStack
                perceiveOrder(exchange, assetPair, order, "open")
            for order in orders.sellStack
                perceiveOrder(exchange, assetPair, order, "open")
            for order in orders.filledStack
                perceiveOrder(exchange, assetPair, order, "filled")
            for order in orders.cancelledStack
                perceiveOrder(exchange, assetPair, order, "cancelled")
    return

############################################################
perceiveOrder = (exchange, assetPair, order, status) ->
    orderObj = createOrderObject(exchange, assetPair, order, status)
    key = getOrderObjectKey(orderObj)
    if orderMemory[key]? then perceiveExistingOrder(orderObj)
    else perceiveNewOrder(orderObj)
    return

perceiveExistingOrder = (newOrderObject) ->
    orderKey = getOrderObjectKey(newOrderObject)
    orderObject = orderMemory[orderKey] 
    ideaKey = orderObject.ideaKey

    if !ideaKey? or !ideaMemory[ideaKey]?
        orderObject.status = newOrderObject.status
        return       
        
    idea = ideaMemory[ideaKey]

    # log "peceived existing Order having an idea attached"
    # olog idea

    if newOrderObject.status == "filled"
        # log "the order got filled!"
        orderObject.status = "filled"
        idea.isFilled = true
        ownr = idea.owner
        event = {type:"filled", idea: idea}
        allModules[ownr].noticeRelevantEvents([event])
        return
    
    if newOrderObject.status == "cancelled"
        # log "the order got cancelled!"
        orderObject.status = "cancelled"
        idea.isCancelled = true
        ownr = idea.owner
        event = {type:"cancelled", idea: idea}
        allModules[ownr].noticeRelevantEvents([event])
        return
    
    # log "nothing special was with that order!"
    # log " - - - "
    return

perceiveNewOrder = (orderObject) ->
    key = getOrderObjectKey(orderObject)
    remember(orderObject, key, orderMemory, memoryDecayMS)
    newOrders.push orderObject
    return

#endregion

############################################################
#region recognizeOrderPlacementActionEffects
recognizeOrderPlacementActionEffects = ->
    log "recognizeOrderPlacementActionEffects"
    for key,action of actionMemory when action.type == "placeOrder"
        order = findAppropriateNewOrderForAction(action)
        continue unless order
        connectNewOrderToIdea(order, action.idea)
        if order.status == "filled"
            action.idea.isFilled = true
            ownr = action.idea.owner
            event = {type:"instaFill", idea:action.idea}
            allModules[ownr].noticeRelevantEvents([event])
        if order.status == "cancelled"
            action.idea.isCancelled = true
            ownr = action.idea.owner
            event = {type:"instaCancel", idea:action.idea}
            allModules[ownr].noticeRelevantEvents([event])

    newOrders.length = 0
    return

findAppropriateNewOrderForAction = (action) ->
    log "findAppropriateNewOrderForAction"
    idea = action.idea
    for order in newOrders
        continue unless orderIsRecentEnoughForAction(order)
        if orderFitsIdea(order, idea) then return order
    return null

#endregion

############################################################
#region processIdeas
processIdeas = ->
    log "processIdeas"
    perceiveAllIdeas()
    createOrderConnections()
    createAllActions()
    return

############################################################
#region perceiveAllIdeas
perceiveAllIdeas = ->
    # log "perceiveAllIdeas"
    for strategy in strategies
        ideas = strategy.getRelevantIdeas()
        # olog ideas
        ideaDecayMS = strategy.ideaDecayMS
        if !ideaDecayMS then ideaDecayMS = memoryDecayMS
        perceiveIdeas(ideas, ideaDecayMS)
    return

perceiveIdeas = (ideas, ideaDecayMS) ->
    # log "perceiveIdeas"
    return unless ideas
    for exchange,pairMap of ideas
        for assetPair,ideaList of pairMap
            for idea in ideaList
                key = getIdeaKey(idea)
                remember(idea, key, ideaMemory, ideaDecayMS)
    return

#endregion

############################################################
createOrderConnections = ->
    # log "createOrderConnections"
    for ideaKey,idea of ideaMemory when idea.id
        orderKey = getOrderKey(idea.exchange, idea.assetPair, idea.id)
        order = orderMemory[orderKey]
        if order? then order.ideaKey = ideaKey
    
    for orderKey,orderObject of orderMemory when orderObject.ideaKey
        idea = ideaMemory[orderObject.ideaKey]
        if idea? then idea.id = ""+orderObject.id

    return

############################################################
#region createAllActions
createAllActions = ->
    # log "createAllActions"
    createAllOrderPlacementActions()
    createAllCancelActions()
    return

############################################################
createAllCancelActions = ->
    # log "createAllCancelActions"
    for orderKey,orderObject of orderMemory when orderObject.ideaKey
        continue unless ideaMemory[orderObject.ideaKey]
        continue unless ideaMemory[orderObject.ideaKey].cancelledSignal
        createCancelAction(orderObject)

    return

createAllOrderPlacementActions = ->
    # log "createAllOrderPlacementActions"
    for key,idea of ideaMemory
        continue if idea.isRealized
        continue if idea.isFilled
        continue if idea.isCancelled
        continue if idea.cancelledSignal
        if ideaIsStupid(idea)
            idea.isStupid = true
            ownr = idea.owner
            event = {type:"stupidIdeaNoticed", idea:idea}
            allModules[ownr].noticeRelevantEvents([event])
            continue
        createOrderPlacementAction(idea)
    return 

############################################################
createOrderPlacementAction = (orderIdea) ->
    # log "createOrderPlacementAction"
    action = {}
    action.type = "placeOrder"
    action.idea = orderIdea

    key = "placeOrder^"+getIdeaKey(orderIdea)
    if actionMemory[key]? then return
    
    remember(action, key, actionMemory, chillTimeMS)
    # olog action
    newActions.push action
    return

createCancelAction = (orderObject) ->
    # log "createCancelAction"
    action = {}
    action.type = "cancelOrder"
    action.exchange = orderObject.exchange
    action.order = orderObject

    key = JSON.stringify(action)
    if actionMemory[key]? then return
    
    remember(action, key, actionMemory, chillTimeMS)
    # olog action
    newActions.push action
    return

#endregion

#endregion

############################################################
#region act
act = ->
    log "act"
    for action in newActions
        if action.type == "placeOrder"
            order = {}
            order.pair = action.idea.assetPair
            order.type = action.idea.type
            order.price = action.idea.price
            order.volume = action.idea.volume
            sendPlaceOrderRequest(action.idea.exchange, order)
            action.idea.isActed = true
        if action.type == "cancelOrder"
            order = {}
            order.id = action.order.id
            order.pair = action.order.assetPair
            sendCancelRequest(action.order.exchange, order)
    
    newActions.length = 0
    return

############################################################
sendCancelRequest = (exchange,orders) ->
    log "sendCancelRequest"
    # olog orders
    # return
    try await network.cancelOrders(exchange, orders)
    catch err then log err
    return

sendPlaceOrderRequest = (exchange, orders) ->
    log "sendPlaceOrderRequest"
    # olog orders
    # return
    try await network.placeOrders(exchange, orders)
    catch err then log err
    return

#endregion

############################################################
checkAlienBudgetUsage = ->
    budgetManager.freeAllBudgetsForStrategy("none")
    for orderId,order of orderMemory
        allocateAlienBudgetFor(order)
    return

allocateAlienBudgetFor = (order) ->
    if order.ideaKey then return
    return unless order.status ==  "open"
    exchange = order.exchange
    assetPair = order.assetPair
    volume = order.volume

    assets = assetPair.split("-")
    asset = assets[0]

    if order.type == "buy" 
        volume = volume * order.price
        asset = assets[1]
    
    # olog order
    # log "allocating volume: " + volume
    # log " - - - "
    try budgetManager.allocate("none", exchange, asset, volume)
    catch error then log error.stack

    return

############################################################
saveMemory = ->
    log "saveMemory"
    state.save("actionMemory", actionMemory)
    state.save("ideaMemory", ideaMemory)
    state.save("orderMemory", orderMemory)
    return

############################################################
#region miscellaneousHelperFunctions
connectNewOrderToIdea = (orderObject, idea) ->
    # log "connectNewOrderToIdea"
    ideaKey = getIdeaKey(idea)
    orderObject.ideaKey = ideaKey
    idea.isRealized = true
    idea.id = ""+orderObject.id
    return

createOrderObject = (exchange, assetPair, order, status) ->
    orderObject = {}
    orderObject.exchange = exchange
    orderObject.assetPair = assetPair
    Object.assign(orderObject, order)
    orderObject.status = status
    return orderObject

getOrderObjectKey = (orderObject) ->
    exchange = orderObject.exchange
    assetPair = orderObject.assetPair
    orderId = orderObject.id
    key = getOrderKey(exchange, assetPair, orderId)
    return key

getOrderKey = (exchange, assetPair, orderId) ->
    identifiers = []
    identifiers.push exchange
    identifiers.push assetPair
    identifiers.push ""+orderId
    key = identifiers.join("^")
    return key

getIdeaKey = (idea) ->
    identifiers = []
    identifiers.push idea.owner
    identifiers.push idea.exchange
    identifiers.push idea.assetPair
    identifiers.push idea.type
    identifiers.push idea.price
    identifiers.push idea.volume
    key = identifiers.join("^")
    return key

orderFitsIdea = (order, idea) ->
    # log "orderFitsIdea?"

    return false unless order.exchange == idea.exchange
    return false unless order.assetPair == idea.assetPair
    return false unless order.price == idea.price
    return false unless order.volume == idea.volume
    return false unless order.type == idea.type

    log " -> yess !!"
    log "order:"
    olog order
    log "idea"
    olog idea
    return true

orderIsRecentEnoughForAction = (order) ->
    return true if order.status == "open"
    date = new Date(order.time)
    now = new Date()
    age = now - date
    return age < chillTimeMS

remember = (object, key, memory, decayMS) ->
    if memory[key] then decayIsActive = true
    memory[key] = object
    return if decayIsActive
    letForget(key, memory, decayMS)
    return

letForget = (key, memory, decayMS) ->
    forget = -> delete memory[key]
    setTimeout(forget, decayMS)
    return

ideaIsStupid = (idea) ->
    # log "ideaIsStupid"
    return false if idea.id
    return false if idea.goStubborn

    exchange = idea.exchange
    assetPair = idea.assetPair
    assets = assetPair.split("-")
    prices = situations[exchange].assets[assets[0]].pricesTo[assets[1]]
    latestPrice = prices.closingPrice
    priceIdea = idea.price

    # log "idea.type: "+idea.type
    # log "latestPrice: "+latestPrice
    # log "priceIdea: "+priceIdea 
    
    if idea.type == "buy" and latestPrice < priceIdea 
        # log "buy price larger than market price - this is stupid!"
        return true
    if idea.type == "sell" and latestPrice > priceIdea 
        # log "This was a stupid sell Idea!"
        return true

    return true unless utl.ideaIsAffordable(idea)
    return false

#endregion

#endregion

############################################################
#region exposedStuff
intelligencemodule.startProcessing = ->
    log "intelligencemodule.startProcessing"
    strategy.start() for strategy in strategies
    setInterval(processCycle, cyclePeriodMS)
    return

############################################################
intelligencemodule.getActionMemory = -> actionMemory
intelligencemodule.getIdeaMemory = -> ideaMemory
intelligencemodule.getOrderMemory = -> orderMemory

#endregion

module.exports = intelligencemodule