--!strict
--!optimize 2

-- Internal: re-entrancy-safe doubly-linked subscriber list.
-- Used by Signal and Store to manage listener delivery.
--
-- Re-entrancy model:
--   fireDepth tracks nested fire() calls on the same list.
--   A Disconnect() during fire() sets isConnected=false and defers the actual
--   list unlink until the outermost fire() returns (fireDepth reaches 0).
--   This prevents list corruption when a listener disconnects itself or others.
--
-- Secondary argument:
--   fire() accepts an optional second argument. Signal ignores it (passes nil);
--   Store uses it to deliver the previous value alongside the new one.

export type Node = {
	listener:        (any, any?) -> (),
	nextNode:        Node?,
	previousNode:    Node?,
	isConnected:     boolean,
}

export type SubscriberList = {
	headNode:         Node?,
	tailNode:         Node?,
	fireDepth:        number,
	hasPendingClean:  boolean,
}

local SubscriberList = {}

function SubscriberList.create(): SubscriberList
	return {
		headNode        = nil,
		tailNode        = nil,
		fireDepth       = 0,
		hasPendingClean = false,
	}
end

-- Appends a listener to the list. Returns two closures for Connection.create:
--   isStillConnected  — returns true while the node is in the active list.
--   performDisconnect — marks the node disconnected; defers unlink if inside fire().
function SubscriberList.append(
	list:     SubscriberList,
	listener: (any, any?) -> ()
): (() -> boolean, () -> ())
	local node: Node = {
		listener     = listener,
		nextNode     = nil,
		previousNode = list.tailNode,
		isConnected  = true,
	}

	if list.tailNode then
		list.tailNode.nextNode = node
	else
		list.headNode = node
	end
	list.tailNode = node

	local function isStillConnected(): boolean
		return node.isConnected
	end

	local function performDisconnect()
		if not node.isConnected then return end
		node.isConnected = false

		if list.fireDepth > 0 then
			list.hasPendingClean = true
			return
		end

		local previousNode: Node? = node.previousNode
		local nextNode:     Node? = node.nextNode
		if previousNode then previousNode.nextNode  = nextNode     else list.headNode = nextNode  end
		if nextNode     then nextNode.previousNode  = previousNode else list.tailNode = previousNode end
		node.previousNode = nil
		node.nextNode     = nil
	end

	return isStillConnected, performDisconnect
end

-- Delivers payload (and optional secondaryArg) to every connected listener.
-- Re-entrant calls are safe; disconnected nodes are swept after the outermost
-- fire() unwinds.
function SubscriberList.fire(list: SubscriberList, payload: any, secondaryArg: any?)
	list.fireDepth += 1

	local currentNode: Node? = list.headNode
	while currentNode do
		local nextNode: Node? = currentNode.nextNode
		if currentNode.isConnected then
			currentNode.listener(payload, secondaryArg)
		end
		currentNode = nextNode
	end

	list.fireDepth -= 1

	if list.fireDepth == 0 and list.hasPendingClean then
		list.hasPendingClean = false
		local sweepNode: Node? = list.headNode
		while sweepNode do
			local nextSweepNode: Node? = sweepNode.nextNode
			if not sweepNode.isConnected then
				local previousNode: Node? = sweepNode.previousNode
				local nextNode:     Node? = sweepNode.nextNode
				if previousNode then previousNode.nextNode  = nextNode     else list.headNode = nextNode  end
				if nextNode     then nextNode.previousNode  = previousNode else list.tailNode = previousNode end
			end
			sweepNode = nextSweepNode
		end
	end
end

-- Marks every node as disconnected and empties the list.
-- Called when the owning Signal or Store is destroyed.
function SubscriberList.destroyAll(list: SubscriberList)
	local currentNode: Node? = list.headNode
	while currentNode do
		currentNode.isConnected = false
		currentNode             = currentNode.nextNode
	end
	list.headNode        = nil
	list.tailNode        = nil
	list.hasPendingClean = false
end

function SubscriberList.isEmpty(list: SubscriberList): boolean
	return list.headNode == nil
end

return table.freeze(SubscriberList)

