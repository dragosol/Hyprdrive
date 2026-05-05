#include "OverviewPassElement.hpp"
#include <hyprland/src/render/OpenGL.hpp>
#include "IOverview.hpp"

CScrollOverviewPassElement::CScrollOverviewPassElement() {
    ;
}

void CScrollOverviewPassElement::draw(const CRegion& damage) {
    g_pScrollOverview->fullRender();
}

bool CScrollOverviewPassElement::needsLiveBlur() {
    return false;
}

bool CScrollOverviewPassElement::needsPrecomputeBlur() {
    return false;
}

std::optional<CBox> CScrollOverviewPassElement::boundingBox() {
    if (!g_pScrollOverview->pMonitor)
        return std::nullopt;

    return CBox{{}, g_pScrollOverview->pMonitor->m_size};
}

CRegion CScrollOverviewPassElement::opaqueRegion() {
    if (!g_pScrollOverview->pMonitor)
        return CRegion{};

    return CBox{{}, g_pScrollOverview->pMonitor->m_size};
}
