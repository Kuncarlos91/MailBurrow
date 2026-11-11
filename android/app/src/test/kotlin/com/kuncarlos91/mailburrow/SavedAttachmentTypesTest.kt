package com.kuncarlos91.mailburrow

import org.junit.Assert.assertEquals
import org.junit.Test

class SavedAttachmentTypesTest {
    @Test fun pdfSaveOverridesMissingOrIncorrectArchiveType() {
        val types = SavedAttachmentTypes()
        for (declared in listOf(null, "application/octet-stream", "image/jpeg")) {
            assertEquals("application/pdf", types.forSave("sample.PDF", declared))
        }
    }

    @Test fun repeatPdfOpensDoNotDependOnChangingProviderMetadata() {
        val types = SavedAttachmentTypes()
        types.remember("saved-pdf", types.forSave("sample.pdf", null))
        var providerCalls = 0
        for (provider in listOf(null, "image/jpeg", "application/octet-stream")) {
            assertEquals("application/pdf", types.forOpen("saved-pdf") {
                providerCalls++
                provider
            })
        }
        assertEquals(0, providerCalls)
    }

    @Test fun filesHaveIndependentTypesAndNewSavesReplaceOldMetadata() {
        val types = SavedAttachmentTypes()
        types.remember("one", "application/pdf")
        types.remember("two", "image/png")
        assertEquals("application/pdf", types.forOpen("one") { null })
        assertEquals("image/png", types.forOpen("two") { null })
        types.remember("one", "text/plain")
        assertEquals("text/plain", types.forOpen("one") { null })
    }

    @Test fun selectedDocumentsUseTheirProviderNotAnOriginalAttachmentHint() {
        val types = SavedAttachmentTypes()
        assertEquals("image/png", types.forOpen("selected-image") { "IMAGE/PNG" })
        assertEquals("image/png", types.forOpen("selected-image") { null })
    }

    @Test fun finalReleaseDropsMetadata() {
        val types = SavedAttachmentTypes()
        types.remember("saved", "application/pdf")
        types.forget("saved")
        assertEquals("text/plain", types.forOpen("saved") { "text/plain" })
    }

    @Test fun genericInvalidAndThrowingProvidersStaySafelyGeneric() {
        val types = SavedAttachmentTypes()
        for (value in listOf(null, "", "*/*", "invalid", "application/pdf\nextra")) {
            assertEquals("application/octet-stream", types.forOpen("unknown") { value })
        }
        assertEquals("application/octet-stream", types.forOpen("unknown") { error("provider failure") })
        assertEquals("application/octet-stream", types.forSave("sample", "*/*"))
        assertEquals("text/plain", types.forSave("sample.txt", " Text/Plain; charset=UTF-8 "))
    }
}
