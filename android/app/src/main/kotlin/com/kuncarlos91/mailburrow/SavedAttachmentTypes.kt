package com.kuncarlos91.mailburrow

import java.util.Locale

// Reader-session metadata only. File type selects viewers; it is not a safety verdict.
internal class SavedAttachmentTypes {
    private val types = mutableMapOf<String, String>()

    fun forSave(name: String, declared: String?): String =
        if (name.lowercase(Locale.ROOT).endsWith(".pdf")) "application/pdf"
        else normalize(declared) ?: "application/octet-stream"

    fun remember(location: String, type: String) {
        types[location] = normalize(type) ?: "application/octet-stream"
    }

    fun forOpen(location: String, providerType: () -> String?): String {
        types[location]?.takeUnless { it == "application/octet-stream" }?.let { return it }
        val resolved = try { normalize(providerType()) } catch (_: Exception) { null }
        if (resolved != null && resolved != "application/octet-stream") {
            types[location] = resolved
        }
        return resolved ?: "application/octet-stream"
    }

    fun forget(location: String) { types.remove(location) }

    private fun normalize(value: String?): String? {
        val type = value?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT) ?: return null
        return type.takeIf { Regex("[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+").matches(it) }
    }
}
