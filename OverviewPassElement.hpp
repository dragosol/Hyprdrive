#pragma once
#include <hyprland/src/render/pass/PassElement.hpp>

class CScrollOverviewPassElement : public IPassElement {
  public:
    CScrollOverviewPassElement();
    virtual ~CScrollOverviewPassElement() = default;

    virtual void                draw(const CRegion& damage);
    virtual bool                needsLiveBlur();
    virtual bool                needsPrecomputeBlur();
    virtual std::optional<CBox> boundingBox();
    virtual CRegion             opaqueRegion();

    virtual const char*         passName() {
        return "CScrollOverviewPassElement";
    }
};
