#include "sage3basic.h"

#include "addressTakenAnalysis.h"
#include "defUseQuery.h"
#include "Timer.h"
#include "AnalysisAbstractionLayer.h"


/*************************************************************
 * Copyright: (C) 2013 by Sriram Aananthakrishnan            *
 * Author   : Sriram Aananthakrishnan                        *
 * email    : aananthakris1@llnl.gov                         *
 *************************************************************/

using namespace CodeThorn;
using namespace AnalysisAbstractionLayer;
using namespace SPRAY;

class TestDefUseVarsInfoTraversal : public AstSimpleProcessing
{
  VariableIdMapping& vidm;
  // some stats
  long n_sideeffect;
  long flagRaisedDefSet;
  long flagRaisedUseSet;
  long n_expr, n_decl;

public:
  TestDefUseVarsInfoTraversal(VariableIdMapping& _vidm) 
  : vidm(_vidm),  n_sideeffect(0), flagRaisedDefSet(0), flagRaisedUseSet(0), n_expr(0), n_decl(0) { }
  void visit(SgNode*);
  void updateStats(const DefUseVarsInfo& duvi);
  void atTraversalEnd();
};

void TestDefUseVarsInfoTraversal::updateStats(const DefUseVarsInfo& duvi) {
  if(duvi.isDefSetModByPointer()) {
    ++flagRaisedDefSet;
  }
  if(duvi.isUseSetModByPointer()) {
    ++flagRaisedUseSet;
  }
  if(duvi.isUseAfterDef()) {
    ++n_sideeffect;
  }
}

void TestDefUseVarsInfoTraversal::visit(SgNode* sgn)
{
  DefUseVarsInfo duvi;
  if(isSgExpression(sgn)) {
    ++n_expr;
    duvi = getDefUseVarsInfo(isSgExpression(sgn), vidm);
  }
  else if(isSgVariableDeclaration(sgn)) {
    ++n_decl;
    duvi = getDefUseVarsInfo(isSgVariableDeclaration(sgn), vidm);
  }
  if(!duvi.isDefSetEmpty() ||
     !duvi.isUseSetEmpty() ||
     !duvi.isFunctionCallExpSetEmpty()) {
    updateStats(duvi);
#if 0
    std::cout << "<" << sgn->class_name() << ", " << sgn->unparseToString() << "\n" 
            << duvi.str(vidm) << ">\n";
#endif
  }
}

void TestDefUseVarsInfoTraversal::atTraversalEnd()
{
  std::cout << "DefSetModByPtr: " << flagRaisedDefSet << "\n";
  std::cout << "UseSetModByPtr: " << flagRaisedUseSet << "\n";
  std::cout << "n_expr: " << n_expr << "\n";
  std::cout << "n_decl: " << n_decl << "\n";
  std::cout << "n_sideeffect: " << n_sideeffect << "\n";
}


/*************************************************
 ******************* main ************************
 *************************************************/
int main(int argc, char* argv[])
{
  // Build the AST used by ROSE
  SgProject* project = frontend(argc,argv);
  SgNode* root = project;

  RoseAst ast(root);

  Timer timer;

  timer.start();

  // compute variableId mappings
  VariableIdMapping vidm;
  vidm.computeVariableSymbolMapping(project);

  // collect all the variables that are used in functions in
  // the code we are analyzing
  // collect type information only about these variables
  VariableIdSet usedVarsInProgram = usedVariablesInsideFunctions(project, &vidm);

  FlowInsensitivePointerInfo fipi(project, vidm, usedVarsInProgram);
  fipi.collectInfo();
  fipi.printInfoSets();

  timer.stop();
  double fipaMeasuredTime=timer.getElapsedTimeInMilliSec();

  TestDefUseVarsInfoTraversal tt(vidm);
  // change to traverse for entire project
  timer.start();
  tt.traverse(project, preorder);
  timer.stop();

  double duMeasuredTime = timer.getElapsedTimeInMilliSec();

  std::cout << "fipa : " << fipaMeasuredTime << "\n";
  std::cout << "du : " << duMeasuredTime << "\n";

  return 0;
}
