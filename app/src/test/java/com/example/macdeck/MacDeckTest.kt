package com.example.macdeck

import org.junit.Test
import kotlinx.serialization.encodeToString

class MacDeckTest {
    @Test
    fun printClientCommand() {
        val trigger = TriggerSlotCommand(pageID = "test-page", slotIndex = 3)
        val jsonText = clientJson.encodeToString(ClientCommand.serializer(), trigger)
        println("SERIALIZED: " + jsonText)
    }
}
