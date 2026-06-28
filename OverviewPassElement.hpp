#pragma once
#include "globals.hpp"
#include <hyprland/src/render/pass/PassElement.hpp>

class CScrollOverviewPassElement : public IPassElement {
  public:
    CScrollOverviewPassElement();
    ~CScrollOverviewPassElement() override = default;

    std::vector<UP<IPassElement>> draw() override;
    ePassElementType              type() override {
        return EK_CUSTOM;
    }
    bool                          needsLiveBlur() override;
    bool                          needsPrecomputeBlur() override;
    std::optional<CBox>           boundingBox() override;
    CRegion                       opaqueRegion() override;

    const char*                   passName() override {
        return "CScrollOverviewPassElement";
    }
};

class COverviewShadowPassElement : public IPassElement {
  public:
    struct SData {
        PHLMONITORREF monitor;
        CBox          fullBox;
        CBox          cutoutBox;
        int           rounding      = 0;
        float         roundingPower = 2.F;
        int           range         = 0;
        int           renderPower   = 0;
        CHyprColor    color;
        float         alpha        = 1.F;
        bool          ignoreWindow = true;
    };

    COverviewShadowPassElement(const SData& data_);
    ~COverviewShadowPassElement() override = default;

    std::vector<UP<IPassElement>> draw() override;
    ePassElementType              type() override {
        return EK_CUSTOM;
    }
    bool                          needsLiveBlur() override;
    bool                          needsPrecomputeBlur() override;
    std::optional<CBox>           boundingBox() override;
    CRegion                       opaqueRegion() override;

    const char*                   passName() override {
        return "COverviewShadowPassElement";
    }

  private:
    SData data;
};
